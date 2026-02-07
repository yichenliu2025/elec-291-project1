$MODMAX10

;========================================================
; Reflow Oven Controller (Stage 1 Bring-up)
; DE10-Lite: SSR control on IO15 = P4.6
;
; ADC0 = LM335 cold junction temperature
; ADC1 = LM4040 reference
; ADC2 = OP07 thermocouple amplifier output (Vout)
;
; OFFSET CALIBRATION on ADC2 at startup:
;   Voff_mV = average(Vout_mV) during first ~300ms
;
; Then each loop:
;   Vdiff_mV = Vout_mV - Voff_mV   (can be negative)
;   deltaT10 = round( Vdiff_mV * 100 / 123 )   (0.1°C)
;   Thot10   = Tcold10 + deltaT10
;
; Display Thot on HEX4..HEX0 as XXXX.X (dp at HEX1)
; Sign (if negative) shown on HEX5 ('-' or blank).
;
; FSM (simple test):
;   state 0 IDLE   -> SSR OFF
;   state 1 HEAT70 -> SSR ON until Thot10 >= 700 (70.0°C)
;   state 2 DONE   -> SSR OFF
;   state 3 ABORT  -> SSR OFF
;
; Safety (in HEAT70):
;   if after 60 seconds Thot10 < 500 (50.0°C) -> ABORT
;
; NOTE: For your BJT driver (2N3904, 1k base resistor, SSR+ to +5V):
;       P4.6 HIGH => transistor ON => SSR ON
;       P4.6 LOW  => transistor OFF => SSR OFF
;========================================================

    CSEG at 0
    ljmp mycode

;----------------------------
; SSR Output (DE10-Lite IO15)
;----------------------------
SSR_OUT     equ P4.6
ELCD_D7     equ P0.1
ELCD_D6     equ P0.3
ELCD_D5     equ P0.5
ELCD_D4     equ P0.7
ELCD_RS     equ P1.7
ELCD_E      equ TXD

;----------------------------
; RAM
;----------------------------
dseg at 30h
x:           ds 4
y:           ds 4
bcd:         ds 5
adc0_32:     ds 4
adc1_32:     ds 4
adc2_32:     ds 4

tcold10:     ds 4        ; 0.1°C
voff_mV:     ds 4        ; mV
vout_mV:     ds 4        ; mV
vdiff_mV:    ds 4        ; mV (signed)
deltat10:    ds 4        ; 0.1°C (signed)
thot10:      ds 4        ; 0.1°C (signed) copy of computed Thot10

; FSM vars
state:       ds 1        ; 0=IDLE, 1=HEAT_TO_70, 2=DONE, 3=ABORT
tick200:     ds 1        ; 0..4  (5*200ms = 1s)
sec_in_heat: ds 2        ; seconds in HEAT_TO_70

bseg
mf:          dbit 1

$include(math32.asm)

cseg

$include(LCD_4bit_DE10Lite_no_RW.inc)

;========================================================
; 7-seg LUT
;========================================================
myLUT:
    DB 0xC0, 0xF9, 0xA4, 0xB0, 0x99
    DB 0x92, 0x82, 0xF8, 0x80, 0x90
    DB 0x88, 0x83, 0xC6, 0xA1, 0x86, 0x8E

;========================================================
; Delays
;========================================================
Delay1ms:
    mov TMOD, #01h
    mov TH0, #0EFh
    mov TL0, #0A9h
    setb TR0
D1_wait:
    jnb TF0, D1_wait
    clr TR0
    clr TF0
    ret

DelaySmall:
    lcall Delay1ms
    ret

Delay50ms:
    mov R0, #50
D50_L0:
    lcall Delay1ms
    djnz R0, D50_L0
    ret

Delay200ms:
    lcall Delay50ms
    lcall Delay50ms
    lcall Delay50ms
    lcall Delay50ms
    ret

;========================================================
; SSR control helpers
;========================================================
SSR_On:
    setb SSR_OUT
    ret

SSR_Off:
    clr  SSR_OUT
    ret

;========================================================
; Display signed XXXX.X on HEX4..HEX0, sign on HEX5
; Input: x = value*10 (0.1°C), signed 32-bit
;========================================================
Display_SignedTemp1dp:
    ; sign check
    mov a, x+3
    jb  ACC.7, ds_neg

ds_pos:
    mov HEX5, #0FFh        ; blank
    ljmp ds_abs

ds_neg:
    mov HEX5, #0BFh        ; '-'
    ; x = abs(x) (two's complement)
    mov a, x+0
    cpl a
    mov x+0, a
    mov a, x+1
    cpl a
    mov x+1, a
    mov a, x+2
    cpl a
    mov x+2, a
    mov a, x+3
    cpl a
    mov x+3, a
    Load_y(1)
    lcall add32

ds_abs:
    ; now x is positive magnitude
    lcall hex2bcd
    mov dptr, #myLUT

    ; Ten-thousands -> HEX4  (bcd+2 low nibble)
    mov a, bcd+2
    anl a, #0FH
    movc a, @a+dptr
    mov HEX4, a

    ; Thousands -> HEX3
    mov a, bcd+1
    swap a
    anl a, #0FH
    movc a, @a+dptr
    mov HEX3, a

    ; Hundreds -> HEX2
    mov a, bcd+1
    anl a, #0FH
    movc a, @a+dptr
    mov HEX2, a

    ; Tens -> HEX1 (dp ON)
    mov a, bcd+0
    swap a
    anl a, #0FH
    movc a, @a+dptr
    anl a, #07Fh
    mov HEX1, a

    ; Ones -> HEX0
    mov a, bcd+0
    anl a, #0FH
    movc a, @a+dptr
    mov HEX0, a
    ret

;========================================================
; Display signed XXXX.X on LCD row 1
;========================================================
Display_SignedTemp1dp_LCD:
    mov x+0, thot10+0
    mov x+1, thot10+1
    mov x+2, thot10+2
    mov x+3, thot10+3

    mov a, x+3
    jb  ACC.7, lcd_neg

lcd_pos:
    mov r6, #' '
    ljmp lcd_abs

lcd_neg:
    mov r6, #'-'
    mov a, x+0
    cpl a
    mov x+0, a
    mov a, x+1
    cpl a
    mov x+1, a
    mov a, x+2
    cpl a
    mov x+2, a
    mov a, x+3
    cpl a
    mov x+3, a
    Load_y(1)
    lcall add32

lcd_abs:
    lcall hex2bcd

    Set_Cursor(1, 1)
    Send_Constant_String(#lcd_label)
    mov a, r6
    lcall ?WriteData

    mov a, bcd+2
    anl a, #0FH
    orl a, #30h
    lcall ?WriteData

    mov a, bcd+1
    swap a
    anl a, #0FH
    orl a, #30h
    lcall ?WriteData

    mov a, bcd+1
    anl a, #0FH
    orl a, #30h
    lcall ?WriteData

    mov a, bcd+0
    swap a
    anl a, #0FH
    orl a, #30h
    lcall ?WriteData

    mov a, #'.'
    lcall ?WriteData

    mov a, bcd+0
    anl a, #0FH
    orl a, #30h
    lcall ?WriteData
    ret

lcd_label:
    DB 'T=', 0

ShowErr:
    ; show 9999.9
    Load_x(99999)
    lcall Display_SignedTemp1dp
    ret

;========================================================
; Read ADC channels
;========================================================
ReadADC0:
    mov ADC_C, #00h
    lcall DelaySmall
    lcall Delay50ms
    mov adc0_32+3, #0
    mov adc0_32+2, #0
    mov adc0_32+1, ADC_H
    mov adc0_32+0, ADC_L
    ret

ReadADC1:
    mov ADC_C, #01h
    lcall DelaySmall
    lcall Delay50ms
    mov adc1_32+3, #0
    mov adc1_32+2, #0
    mov adc1_32+1, ADC_H
    mov adc1_32+0, ADC_L
    ret

ReadADC2:
    mov ADC_C, #02h
    lcall DelaySmall
    lcall Delay50ms
    mov adc2_32+3, #0
    mov adc2_32+2, #0
    mov adc2_32+1, ADC_H
    mov adc2_32+0, ADC_L
    ret

;========================================================
; Convert ADC2 to mV using ADC1 reference
; return: x = mV (unsigned)
;========================================================
ADC2_to_mV:
    ; x = ADC2
    mov x+3, #0
    mov x+2, #0
    mov x+1, adc2_32+1
    mov x+0, adc2_32+0
    Load_y(4096)
    lcall mul32

    ; y = ADC1
    mov y+3, #0
    mov y+2, #0
    mov y+1, adc1_32+1
    mov y+0, adc1_32+0
    lcall div32
    ret

;========================================================
; FSM Update (called once per second)
; Uses thot10 (signed 0.1°C)
;========================================================
FSM_1s_Update:
    mov a, state
    cjne a, #1, fsm_not_heat   ; only act in HEAT_TO_70

    ; sec_in_heat++
    inc sec_in_heat+0
    mov a, sec_in_heat+0
    jnz heat_sec_ok
    inc sec_in_heat+1
heat_sec_ok:

    ;-----------------------------------------
    ; If Thot10 >= 700 => DONE (SSR OFF)
    ;-----------------------------------------
    mov x+0, thot10+0
    mov x+1, thot10+1
    mov x+2, thot10+2
    mov x+3, thot10+3
    Load_y(700)
    lcall sub32                ; x = Thot10 - 700
    mov a, x+3
    jnb ACC.7, reached70       ; not negative => >= 700

    ;-----------------------------------------
    ; Safety: if sec_in_heat >= 60 AND Thot10 < 500 => ABORT
    ;-----------------------------------------
    mov a, sec_in_heat+1
    jnz sec_ge_60
    mov a, sec_in_heat+0
    clr c
    subb a, #60
    jc  keep_heating           ; <60 seconds -> keep heating

sec_ge_60:
    mov x+0, thot10+0
    mov x+1, thot10+1
    mov x+2, thot10+2
    mov x+3, thot10+3
    Load_y(500)
    lcall sub32                ; x = Thot10 - 500
    mov a, x+3
    jb  ACC.7, do_abort        ; negative => Thot10 < 500

keep_heating:
    lcall SSR_On
    ret

reached70:
    lcall SSR_Off
    mov state, #2              ; DONE
    ret

do_abort:
    lcall SSR_Off
    mov state, #3              ; ABORT
    ret

fsm_not_heat:
    ; IDLE / DONE / ABORT -> SSR OFF
    lcall SSR_Off
    ret

;========================================================
; Main
;========================================================
mycode:
    mov SP, #7FH

    ; SSR output default OFF
    lcall SSR_Off
    lcall ELCD_4BIT

    ; FSM init: start heating immediately
    mov state, #1              ; HEAT_TO_70
    mov tick200, #0
    mov sec_in_heat+0, #0
    mov sec_in_heat+1, #0
    lcall SSR_On               ; <--- IMPORTANT: start SSR immediately (no 1s wait)

    ; reset ADC
    mov ADC_C, #80h
    lcall Delay50ms

    ; read reference
    lcall ReadADC1

    ; guard ADC1 >= 50
    mov a, adc1_32+1
    jnz adc1_ok
    mov a, adc1_32+0
    clr c
    subb a, #50
    jnc adc1_ok
    ljmp ref_bad

adc1_ok:
    ;====================================================
    ; Offset calibration: average 6 samples (~300ms)
    ;====================================================
    Load_x(0)
    mov voff_mV+0, x+0
    mov voff_mV+1, x+1
    mov voff_mV+2, x+2
    mov voff_mV+3, x+3

    mov R7, #6
cal_loop:
    lcall ReadADC2
    lcall ADC2_to_mV          ; x = mV

    ; sum = sum + x
    mov y+0, voff_mV+0
    mov y+1, voff_mV+1
    mov y+2, voff_mV+2
    mov y+3, voff_mV+3
    lcall add32               ; x = x + y
    mov voff_mV+0, x+0
    mov voff_mV+1, x+1
    mov voff_mV+2, x+2
    mov voff_mV+3, x+3
    djnz R7, cal_loop

    ; voff = (sum + 3) / 6  (round)
    mov x+0, voff_mV+0
    mov x+1, voff_mV+1
    mov x+2, voff_mV+2
    mov x+3, voff_mV+3
    Load_y(3)
    lcall add32
    Load_y(6)
    lcall div32
    mov voff_mV+0, x+0
    mov voff_mV+1, x+1
    mov voff_mV+2, x+2
    mov voff_mV+3, x+3

main_loop:
    ;====================================================
    ; Cold temp (LM335) -> tcold10
    ;====================================================
    lcall ReadADC0

    ; x = ADC0
    mov x+3, #0
    mov x+2, #0
    mov x+1, adc0_32+1
    mov x+0, adc0_32+0
    Load_y(4096)
    lcall mul32

    ; y = ADC1
    mov y+3, #0
    mov y+2, #0
    mov y+1, adc1_32+1
    mov y+0, adc1_32+0
    lcall div32               ; x = mV

    Load_y(10)
    lcall mul32               ; x = mV*10  (K*100)
    Load_y(27315)
    lcall sub32               ; x = C*100

    ; if negative -> clamp to 0
    mov a, x+3
    jnb ACC.7, cold_pos
    Load_x(0)
    ljmp cold_store

cold_pos:
    Load_y(5)
    lcall add32
    Load_y(10)
    lcall div32               ; x = tcold10

cold_store:
    mov tcold10+0, x+0
    mov tcold10+1, x+1
    mov tcold10+2, x+2
    mov tcold10+3, x+3

    ;====================================================
    ; Vdiff = Vout - Voff (mV, signed)
    ;====================================================
    lcall ReadADC2
    lcall ADC2_to_mV          ; x = Vout_mV
    mov vout_mV+0, x+0
    mov vout_mV+1, x+1
    mov vout_mV+2, x+2
    mov vout_mV+3, x+3

    ; x = Vout
    mov x+0, vout_mV+0
    mov x+1, vout_mV+1
    mov x+2, vout_mV+2
    mov x+3, vout_mV+3
    ; y = Voff
    mov y+0, voff_mV+0
    mov y+1, voff_mV+1
    mov y+2, voff_mV+2
    mov y+3, voff_mV+3
    lcall sub32               ; x = Vdiff_mV (signed)
    mov vdiff_mV+0, x+0
    mov vdiff_mV+1, x+1
    mov vdiff_mV+2, x+2
    mov vdiff_mV+3, x+3

    ;====================================================
    ; deltaT10 = round( Vdiff_mV * 100 / 123 )
    ; signed support: handle sign manually
    ;====================================================
    mov a, vdiff_mV+3
    jb  ACC.7, vdiff_neg

vdiff_pos:
    ; x = Vdiff
    mov x+0, vdiff_mV+0
    mov x+1, vdiff_mV+1
    mov x+2, vdiff_mV+2
    mov x+3, vdiff_mV+3
    Load_y(100)
    lcall mul32
    Load_y(61)
    lcall add32
    Load_y(123)
    lcall div32               ; x = deltaT10 (positive)
    mov deltat10+0, x+0
    mov deltat10+1, x+1
    mov deltat10+2, x+2
    mov deltat10+3, x+3
    ljmp got_delta

vdiff_neg:
    ; x = abs(Vdiff)
    mov x+0, vdiff_mV+0
    mov x+1, vdiff_mV+1
    mov x+2, vdiff_mV+2
    mov x+3, vdiff_mV+3
    ; abs: two's complement
    mov a, x+0
    cpl a
    mov x+0, a
    mov a, x+1
    cpl a
    mov x+1, a
    mov a, x+2
    cpl a
    mov x+2, a
    mov a, x+3
    cpl a
    mov x+3, a
    Load_y(1)
    lcall add32

    ; now compute magnitude
    Load_y(100)
    lcall mul32
    Load_y(61)
    lcall add32
    Load_y(123)
    lcall div32               ; x = |deltaT10|

    ; make it negative
    mov a, x+0
    cpl a
    mov x+0, a
    mov a, x+1
    cpl a
    mov x+1, a
    mov a, x+2
    cpl a
    mov x+2, a
    mov a, x+3
    cpl a
    mov x+3, a
    Load_y(1)
    lcall add32

    mov deltat10+0, x+0
    mov deltat10+1, x+1
    mov deltat10+2, x+2
    mov deltat10+3, x+3

got_delta:
    ;====================================================
    ; Thot10 = Tcold10 + deltaT10
    ;====================================================
    mov x+0, deltat10+0
    mov x+1, deltat10+1
    mov x+2, deltat10+2
    mov x+3, deltat10+3

    mov y+0, tcold10+0
    mov y+1, tcold10+1
    mov y+2, tcold10+2
    mov y+3, tcold10+3

    lcall add32               ; x = Thot10 (signed)

    ; store Thot10 copy for FSM comparisons
    mov thot10+0, x+0
    mov thot10+1, x+1
    mov thot10+2, x+2
    mov thot10+3, x+3

    ; Display signed Thot10
    lcall Display_SignedTemp1dp
    lcall Display_SignedTemp1dp_LCD

    ;====================================================
    ; Immediate cutoff: stop heating as soon as Thot10 >= 700
    ;====================================================
    mov x+0, thot10+0
    mov x+1, thot10+1
    mov x+2, thot10+2
    mov x+3, thot10+3
    Load_y(700)
    lcall sub32                ; x = Thot10 - 700
    mov a, x+3
    jb  ACC.7, keep_heating_now
    lcall SSR_Off
    mov state, #2              ; DONE
    ljmp loop_again

keep_heating_now:
    ;====================================================
    ; Timebase: 200ms tick; run FSM once per 1 second
    ;====================================================
    lcall Delay200ms

    inc tick200
    mov a, tick200
    cjne a, #5, loop_again
    mov tick200, #0

    ; once per second: update FSM (ON/OFF/ABORT/DONE)
    lcall FSM_1s_Update

loop_again:
    ljmp main_loop

ref_bad:
    lcall SSR_Off
    mov state, #3            ; ABORT
    lcall ShowErr
    lcall Delay200ms
    ljmp main_loop

end

