#pragma once
// LEO TFT kiosk — tunables. Display/touch pins are build flags in platformio.ini.

#define FW_VERSION        "0.1.0"
#define PROTO_VERSION     1
#define SERIAL_BAUD       115200
#define MAX_LINE          1024      // longest accepted frame (bytes); longer → ERROR too_long

#define PIN_BOOT          0         // on-board BOOT button: physical confirm for pairing

#define PAIR_CONFIRM_MS   60000     // the user has 60 s to confirm a pairing code on the device
#define PAIR_KEY_WINDOW_MS 30000    // after confirming, the desktop has 30 s to send the key
#define LINK_TIMEOUT_MS   6000      // no valid frame for this long → "desktop not connected"
#define BOOT_CAL_HOLD_MS  3000      // hold BOOT 3 s → touch calibration
#define BOOT_UNPAIR_HOLD_MS 8000    // hold BOOT 8 s → forget the pairing key (physical reset)

#define TOUCH_CAL_MIN_RANGE 1500    // reject calibrations where the corners weren't really touched
