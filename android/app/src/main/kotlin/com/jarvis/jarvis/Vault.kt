package com.jarvis.jarvis

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * LEO's encryption at rest — envelope encryption (the same design as Jetpack Security / Tink):
 *
 *  • KEK: an AES-256-GCM key generated INSIDE the Android Keystore (TEE or StrongBox). It can never
 *    be exported or read by any app, including LEO; it only wraps/unwraps the data keys below.
 *  • DEK: a random 256-bit AES-GCM data key + a 256-bit HMAC key, stored only in wrapped form.
 *    Unwrapped once per process, kept in memory, never logged or written in plaintext.
 *  • Every value: AES-256-GCM, fresh random 96-bit IV, 128-bit tag, and Associated Data binding it to
 *    the Android user + table + column. Moving a ciphertext to another field/user fails to decrypt.
 *  • Search: HMAC-SHA256 "blind" tokens of keywords, so the search index holds no readable words.
 *  • Wipe = crypto-shredding: delete the KEK and wrapped keys; every ciphertext becomes unreadable.
 */
object Vault {
    private const val KEK_ALIAS = "leo_kek_v1"
    private const val PREFS = "leo_vault"
    private const val PREFIX = "v1:"
    private val rnd = SecureRandom()

    @Volatile private var dek: SecretKey? = null
    @Volatile private var macKey: SecretKey? = null

    /** Android user (profile) this process runs as — part of every value's Associated Data. */
    private val userId: Int get() = android.os.Process.myUid() / 100000

    private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun kek(): SecretKey {
        val ks = keyStore()
        (ks.getKey(KEK_ALIAS, null) as? SecretKey)?.let { return it }
        fun gen(strongBox: Boolean): SecretKey {
            val spec = KeyGenParameterSpec.Builder(KEK_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .apply { if (strongBox && Build.VERSION.SDK_INT >= 28) setIsStrongBoxBacked(true) }
                .build()
            return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply { init(spec) }.generateKey()
        }
        return try { gen(true) } catch (_: Exception) { gen(false) } // StrongBox if the phone has it, else TEE
    }

    private fun wrap(k: SecretKey, raw: ByteArray): String {
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, k) }
        c.updateAAD("leo-wrap-v1".toByteArray())
        return Base64.encodeToString(c.iv + c.doFinal(raw), Base64.NO_WRAP)
    }

    private fun unwrap(k: SecretKey, b64: String): ByteArray {
        val all = Base64.decode(b64, Base64.NO_WRAP)
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, k, GCMParameterSpec(128, all, 0, 12)) }
        c.updateAAD("leo-wrap-v1".toByteArray())
        return c.doFinal(all, 12, all.size - 12)
    }

    /** Creates or unlocks the keys. Returns status for the Privacy screen (never key material). */
    @Synchronized
    fun init(ctx: Context): Map<String, Any?> {
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val k = kek()
        var wd = p.getString("dek", null)
        var wm = p.getString("mac", null)
        if (wd == null || wm == null) {
            val d = ByteArray(32).also(rnd::nextBytes)
            val m = ByteArray(32).also(rnd::nextBytes)
            wd = wrap(k, d); wm = wrap(k, m)
            p.edit().putString("dek", wd).putString("mac", wm).commit()
            d.fill(0); m.fill(0)
        }
        val d = unwrap(k, wd)
        val m = unwrap(k, wm)
        dek = SecretKeySpec(d, "AES"); macKey = SecretKeySpec(m, "HmacSHA256")
        d.fill(0); m.fill(0)
        return status()
    }

    fun status(): Map<String, Any?> {
        var level = "unknown"
        var exportable = true
        try {
            val key = keyStore().getKey(KEK_ALIAS, null) as SecretKey
            val info = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java) as KeyInfo
            level = if (Build.VERSION.SDK_INT >= 31) when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> "strongbox"
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "tee"
                KeyProperties.SECURITY_LEVEL_SOFTWARE -> "software"
                else -> "unknown"
            } else @Suppress("DEPRECATION") if (info.isInsideSecureHardware) "tee" else "software"
            exportable = key.encoded != null // Keystore keys return null: the raw key never leaves the keystore
        } catch (_: Exception) {}
        return mapOf("ready" to (dek != null), "cipher" to "AES-256-GCM", "keyStorage" to level,
            "kekExportable" to exportable, "profile" to userId)
    }

    private fun aadBytes(aad: String) = "leo/v1/u$userId/$aad".toByteArray()

    fun seal(plain: List<String?>, aad: String): List<String?> {
        val key = dek ?: throw IllegalStateException("vault_locked")
        val ad = aadBytes(aad)
        return plain.map { s ->
            if (s == null) null else {
                val iv = ByteArray(12).also(rnd::nextBytes)
                val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv)) }
                c.updateAAD(ad)
                PREFIX + Base64.encodeToString(iv + c.doFinal(s.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
            }
        }
    }

    /** Decrypts; a value that fails authentication (tampered, wrong field, wrong user, wrong key) → null. */
    fun open(sealed: List<String?>, aad: String): List<String?> {
        val key = dek ?: throw IllegalStateException("vault_locked")
        val ad = aadBytes(aad)
        return sealed.map { s ->
            when {
                s == null -> null
                !s.startsWith(PREFIX) -> s // legacy plaintext (pre-migration) passes through
                else -> try {
                    val all = Base64.decode(s.substring(PREFIX.length), Base64.NO_WRAP)
                    val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, all, 0, 12)) }
                    c.updateAAD(ad)
                    String(c.doFinal(all, 12, all.size - 12), Charsets.UTF_8)
                } catch (_: Exception) { null }
            }
        }
    }

    /** Keyed search tokens: HMAC-SHA256(word), 16 hex chars, prefixed so FTS treats them as one token. */
    fun blind(words: List<String>): List<String> {
        val key = macKey ?: throw IllegalStateException("vault_locked")
        val mac = Mac.getInstance("HmacSHA256").apply { init(key) }
        return words.map { w -> "b" + mac.doFinal(w.lowercase().toByteArray()).take(8).joinToString("") { "%02x".format(it) } }
    }

    /** Crypto-shredding: destroys the keys, so anything encrypted before is permanently unreadable. */
    @Synchronized
    fun wipe(ctx: Context) {
        dek = null; macKey = null
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().commit()
        try { keyStore().deleteEntry(KEK_ALIAS) } catch (_: Exception) {}
    }

    /** On-device security self-test. Results only (pass/fail + non-secret detail). */
    fun selfTest(ctx: Context): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        fun check(name: String, block: () -> Pair<Boolean, String>) {
            val (ok, detail) = try { block() } catch (e: Exception) { false to (e.javaClass.simpleName) }
            out += mapOf("name" to name, "pass" to ok, "detail" to detail)
        }
        if (dek == null) init(ctx)
        val canary = "LEO-CANARY my OTP is 482913 and my secret plan"
        check("Round trip (AES-256-GCM)") { val s = seal(listOf(canary), "test.t")[0]!!; (open(listOf(s), "test.t")[0] == canary) to "decrypts to the original" }
        check("Ciphertext hides the text") { val s = seal(listOf(canary), "test.t")[0]!!; (!s.contains("482913") && !s.contains("CANARY")) to "${s.length} chars, no plaintext" }
        check("Fresh IV every time") { val a = seal(listOf(canary), "test.t")[0]; val b = seal(listOf(canary), "test.t")[0]; (a != b) to "same text → different ciphertext" }
        check("Tampering detected (GCM tag)") {
            val s = seal(listOf(canary), "test.t")[0]!!
            val raw = Base64.decode(s.substring(3), Base64.NO_WRAP); raw[raw.size - 20] = (raw[raw.size - 20].toInt() xor 1).toByte()
            (open(listOf(PREFIX + Base64.encodeToString(raw, Base64.NO_WRAP)), "test.t")[0] == null) to "1 flipped bit → rejected"
        }
        check("Bound to its field (AAD)") { val s = seal(listOf(canary), "messages.text")[0]; (open(listOf(s), "facts.text")[0] == null) to "moved to another column → rejected" }
        check("Bound to the Android user") {
            val s = seal(listOf(canary), "test.t")[0]!!
            val raw = Base64.decode(s.substring(3), Base64.NO_WRAP)
            val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, dek, GCMParameterSpec(128, raw, 0, 12)) }
            c.updateAAD("leo/v1/u${userId + 1}/test.t".toByteArray())
            val other = try { c.doFinal(raw, 12, raw.size - 12); true } catch (_: Exception) { false }
            (!other) to "another user's context cannot decrypt it"
        }
        check("Wrong key cannot decrypt") {
            val s = seal(listOf(canary), "test.t")[0]!!
            val raw = Base64.decode(s.substring(3), Base64.NO_WRAP)
            val wrong = SecretKeySpec(ByteArray(32).also(rnd::nextBytes), "AES")
            val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, wrong, GCMParameterSpec(128, raw, 0, 12)) }
            c.updateAAD(aadBytes("test.t"))
            val ok = try { c.doFinal(raw, 12, raw.size - 12); false } catch (_: Exception) { true }
            ok to "random key → rejected"
        }
        check("Master key is hardware-backed") { val st = status(); (st["keyStorage"] == "tee" || st["keyStorage"] == "strongbox") to "${st["keyStorage"]}" }
        check("Master key is not exportable") { (status()["kekExportable"] == false) to "Keystore never releases the raw key" }
        check("Data keys stored only wrapped") {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val wd = p.getString("dek", "")!!
            val rawDek = dek!!.encoded
            val leaked = Base64.encodeToString(rawDek, Base64.NO_WRAP)
            (wd.isNotEmpty() && !wd.contains(leaked)) to "only the Keystore-wrapped form is on disk"
        }
        check("Search index holds no words") { val t = blind(listOf("passport")); (t[0] != "passport" && t[0].length == 17) to "\"passport\" → ${t[0].take(6)}…" }
        return out
    }
}
