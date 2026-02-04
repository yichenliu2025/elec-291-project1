$MODMAX10

;===========================================================
; SFR / MMIO definitions (UNCOMMENT / ADJUST IF NEEDED)
;===========================================================
ADC_C   DATA 0A1h
ADC_L   DATA 0A2h
ADC_H   DATA 0A3h

; If your project already defines HEX0..HEX5 elsewhere,
; delete these 6 lines to avoid redefinition errors.
HEX0    DATA 090h
HEX1    DATA 091h
HEX2    DATA 092h
HEX3    DATA 093h
HEX4    DATA 094h
HEX5    DATA 095h

            CSEG    AT 0000h
            LJMP    mycode

;===========================================================
; Data segments
;===========================================================
DSEG    AT 30h
x:          DS 4
y:          DS 4
bcd:        DS 5
adc0_32:     DS 4
adc1_32:     DS 4

BSEG
mf:         DBIT 1

$include(math32.asm)

;===========================================================
; Code
;===========================================================
CSEG

myLUT:
    DB 0C0h, 0F9h, 0A4h, 0B0h, 099h
    DB 092h, 082h, 0F8h, 080h, 090h
    DB 088h, 083h, 0C6h, 0A1h, 086h, 08Eh

;-----------------------------------------
; Small delay (safe short delay)
;-----------------------------------------
DelaySmall:
    NOP
    NOP
    NOP
    RET

;-----------------------------------------
; ~50ms delay (tuned by loops)
;-----------------------------------------
Delay50ms:
    MOV R0, #30
D50_L0:
    MOV R1, #74
D50_L1:
    MOV R2, #250
D50_L2:
    DJNZ R2, D50_L2
    DJNZ R1, D50_L1
    DJNZ R0, D50_L0
    RET

;-----------------------------------------
; ~200ms delay
;-----------------------------------------
Delay200ms:
    LCALL Delay50ms
    LCALL Delay50ms
    LCALL Delay50ms
    LCALL Delay50ms
    RET

;-----------------------------------------
; Display XXXX with 1 decimal: XXX.X
; Decimal point ON at HEX1 (active-low DP assumed)
; Uses bcd[1:0] after hex2bcd:
;   bcd+1: thousands/hundreds
;   bcd+0: tens/ones
;-----------------------------------------
Display_Temp1dp_HEX3to0:
    MOV DPTR, #myLUT

    ; Thousands -> HEX3
    MOV A, bcd+1
    SWAP A
    ANL  A, #0Fh
    MOVC A, @A+DPTR
    MOV  HEX3, A

    ; Hundreds -> HEX2
    MOV A, bcd+1
    ANL  A, #0Fh
    MOVC A, @A+DPTR
    MOV  HEX2, A

    ; Tens -> HEX1 (dp ON)
    MOV A, bcd+0
    SWAP A
    ANL  A, #0Fh
    MOVC A, @A+DPTR
    ANL  A, #07Fh        ; DP on (bit7=0)
    MOV  HEX1, A

    ; Ones -> HEX0  (this is the 0.1°C digit after scaling)
    MOV A, bcd+0
    ANL  A, #0Fh
    MOVC A, @A+DPTR
    MOV  HEX0, A

    ; Unused HEX -> blank/0
    MOV HEX4, #0C0h
    MOV HEX5, #0C0h
    RET

ShowErr9999:
    Load_x(9999)
    LCALL hex2bcd
    LCALL Display_Temp1dp_HEX3to0
    RET

Show0000:
    Load_x(0)
    LCALL hex2bcd
    LCALL Display_Temp1dp_HEX3to0
    RET

;-----------------------------------------
; Read ADC channel into adc?_32
; Adds settle/update delay
;-----------------------------------------
ReadADC0:
    MOV ADC_C, #00h
    LCALL DelaySmall
    LCALL Delay50ms

    MOV adc0_32+3, #00h
    MOV adc0_32+2, #00h
    MOV adc0_32+1, ADC_H
    MOV adc0_32+0, ADC_L
    RET

ReadADC1:
    MOV ADC_C, #01h
    LCALL DelaySmall
    LCALL Delay50ms

    MOV adc1_32+3, #00h
    MOV adc1_32+2, #00h
    MOV adc1_32+1, ADC_H
    MOV adc1_32+0, ADC_L
    RET

;===========================================================
; Main
;===========================================================
mycode:
    MOV SP, #7Fh

    ; Reset ADC block
    MOV ADC_C, #80h
    LCALL Delay50ms

main_loop:
    ;---------------------------
    ; Read reference ADC1
    ;---------------------------
    LCALL ReadADC1

    ; Guard: if ADC1 < 50 -> error (avoid division explosion)
    MOV A, adc1_32+1
    JNZ ref_ok
    MOV A, adc1_32+0
    CLR C
    SUBB A, #50
    JC  ref_bad
ref_ok:

    ;---------------------------
    ; Read sensor ADC0
    ;---------------------------
    LCALL ReadADC0

    ; x = ADC0 (16-bit placed into 32-bit x)
    MOV x+3, #00h
    MOV x+2, #00h
    MOV x+1, adc0_32+1
    MOV x+0, adc0_32+0

    ; x = x * 4096
    Load_y(4096)
    LCALL mul32

    ; y = ADC1
    MOV y+3, #00h
    MOV y+2, #00h
    MOV y+1, adc1_32+1
    MOV y+0, adc1_32+0

    ; x = (ADC0*4096)/ADC1  -> mV (scaled by your divider choice)
    LCALL div32

    ; x = mV * 10
    Load_y(10)
    LCALL mul32

    ; x = C*100 = (mV*10) - 27315
    Load_y(27315)
    LCALL sub32

    ; If negative -> show 0000
    MOV A, x+3
    JB  ACC.7, temp_negative

    ; rounding to 0.1°C:
    ; (C*100 + 5)/10 => C*10
    Load_y(5)
    LCALL add32

    Load_y(10)
    LCALL div32          ; x = C*10

    ; Display XXX.X
    LCALL hex2bcd
    LCALL Display_Temp1dp_HEX3to0

    LCALL Delay200ms
    LJMP main_loop

ref_bad:
    LCALL ShowErr9999
    LCALL Delay200ms
    LJMP main_loop

temp_negative:
    LCALL Show0000
    LCALL Delay200ms
    LJMP main_loop

END
