// =============================================================================
// ESP32-S3 random number sender for the RV32I FPGA project
//
// Every second sends one random number 0 .. 99999999 as a text line, e.g.
// "4821937\n", on UART1 TX = GPIO17 at 115200 baud 8N1. The FPGA receives it
// on Pmod JA1 and the RISC-V program shows it on the display.
//
// Wiring (3.3 V logic on both boards, no level shifter needed):
//   ESP32-S3 GPIO17 (TX)  ->  Nexys A7 Pmod JA pin 1 (top row, first pin)
//   ESP32-S3 GND          ->  Nexys A7 Pmod JA pin 5 (GND)
//   Do NOT connect 3V3/5V between the boards: each one is powered by its USB.
// =============================================================================
#include <Arduino.h>

static const int FPGA_TX_PIN = 17;          // -> Pmod JA1
static const int FPGA_RX_PIN = 18;          // not used (nothing comes back)
static const uint32_t BAUD = 115200;        // must match the FPGA (fpga_top BAUD_RATE)
// one number per second; the "_fast" environments of platformio.ini build it
// with -DPERIOD_MS=0: numbers back to back, a byte every 87 us, so that the
// UART interrupts never stop (to see them next to the other interrupts)
#ifndef PERIOD_MS
#define PERIOD_MS 1000
#endif
static const uint32_t MAX_VALUE = 99999999; // 8 digits = 8 displays

HardwareSerial fpga(1);

void setup() {
    Serial.begin(115200);                   // USB serial: debug messages
    fpga.begin(BAUD, SERIAL_8N1, FPGA_RX_PIN, FPGA_TX_PIN);
    Serial.println("rand_sender: sending to FPGA on GPIO17 at 115200 baud");
}

void loop() {
    // esp_random() uses the chip's hardware random number generator
    uint32_t n = esp_random() % (MAX_VALUE + 1);

    char line[16];
    snprintf(line, sizeof line, "%lu\n", (unsigned long)n);
    fpga.print(line);                       // to the FPGA
    Serial.print("sent: ");
    Serial.print(line);                     // to the PC, for checking

    delay(PERIOD_MS);
}
