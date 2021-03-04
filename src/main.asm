/*
 *  main.asm
 *
 *  Created: 10 Feb 2021 02:38:05 PM
 *  Author: Nicholas Warrener (UntidyRAM)
 *
 *  Description: This is my AVR assembly implementation of the DHT communication protocol. 
 *               It uses four seven segment displays to show the humidity or temperature and a 
 *               push button cycles between the humidity and temperature. A red LED turns on when
 *               the temperature is below zero Celsius. When the display is showing the temperature,
 *               the fourth segment displays a "C". When the display is showing the humidity, the
 *               fourth segment displays an "H".
 *
 *  Copyright (C) 2021 Nicholas Warrener
 *  
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along
 *  with this program; if not, write to the Free Software Foundation, Inc.,
 *  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 *  Please look under the documents section for the full license. 
 *
 *  Release Notes:
 *  25 Feb 2021 - Initial release. 
 *  4 March 2021 - Changed code to use four seven segment displays.
 *               - A red LED turns on when the temperature is below zero.
 *               - When the temperature is displayed, the fourth display shows a "C".
 *               - When the humidity is displayed, the fourth display shows an "H".
 *               - Please see the schematic for the updates in the wiring.
 */

; Assembler Directives
; ### Timer/Counter2 Constants ###
; Use CTC mode
.SET tim2_enable_ctc_mode = (1 << WGM21)
; Enable output compare match A
.SET tim2_enable_output_compare_match_A = (1 << OCIE2A)
; When you assign a prescaler value to a timer register, you start the timer.
; So you should assign the prescaler right before you want the timer to start.
.SET time2_start_with_prescaler_1 = (1 << CS20) | (0 << CS21) | (0 << CS22)
.SET tim2_start_with_prescaler_8 = (0 << CS20) | (1 << CS21) | (0 << CS22)
.SET tim2_start_with_prescaler_64 = (0 << CS20) | (0 << CS21) | (1 << CS22)
.SET tim2_stop = (0 << CS20) | (0 << CS21) | (0 << CS22) ; This prescaler stops the timer.

; ### Sleep Mode Constants ###
.SET idle_enable = (0 << SM0) | (0 << SM1) | (0 << SM2) | (1 << SE)
; Power save is preferred as it saves more power than idle mode. It can't be used during the DHT
; communication method though as the PCINT won't wake the device in this mode. Only idle mode enables this. 
.SET power_save_enable = (1 << SM0) | (1 << SM1) | (0 << SM2) | (1 << SE)

; ### Pin Interrupt Constants ###
.SET int0_enable = (1 << INT0)
.SET int0_level_sense = (1 << ISC01) | (1 << ISC00)
.SET pcint2_enable = (1 << PCIE2)

; ### Watchdog Constants ###
.SET enable_editing = (1 << WDCE) | (1 << WDE)
; If you want to change the duration of the watchdog timer, you can change WDP[3:0]
.SET set_prescaler_enable_interrupt_mode = (0 << WDE) | (1 << WDIE) | (1 << WDP2) | (1 << WDP1) | (0 << WDP0)

; Data memory
.DSEG
.ORG 0x0100
	; Storage for raw data from the sensor
	tempRawHigh: .BYTE 1 ; This byte holds the upper byte of a temperature reading sent from the DHT22
	tempRawLow: .BYTE 1 ; This byte holds the lower byte of a temperature reading sent from the DHT22
	humRawHigh: .BYTE 1 ; This byte holds the upper byte of a humidity reading sent from the DHT22
	humRawLow: .BYTE 1 ; This byte holds the lower byte of a humidity reading sent from the DHT22

	; Storage for processed data (raw data divided by 10)
	wholeNumber: .BYTE 1 ; This byte holds the whole number part of the measurement once rawHigh and rawLow have been divded by ten
	remainder: .BYTE 1 ; This byte holds the remainder part of the measurement once rawHigh and rawLow have been divded by ten
	negTemp: .BYTE 1 ; If the LSB of this byte is set to a one, then we have a negative temperature

	; Utility
	toggle: .BYTE 1 ; We use this byte to work out what value is being displayed. We then know to display the opposite value
	quantityUnit: .BYTE 1 ; This byte holds the bit pattern to either display a "C" or an "H" on the display

; Program memory
.CSEG
.ORG 0x0000 ; RESET
	RJMP init
.ORG 0x0002 ; INT0
	RJMP ISR_PUSH_BUTTON
.ORG 0x000A ; PCINT2
	RJMP ISR_DHT_PIN_CHANGE
.ORG 0x000C ; WDT
	RJMP ISR_WATCHDOG
.ORG 0x000E ; TIMER2 COMPA
	RJMP ISR_TIMER_2

; Interrupt Service Routines
.ORG 0x0036
ISR_PUSH_BUTTON:
	; This code will act really bad if you don't have a debounce circuit
	; connected between the output of the push button and the input to the AVR!
	; Will add a software debounce in the future.
	PUSH R16
	PUSH R17
	PUSH R20

	CLR R16
	CLR R17
	CLR R20

	IN R20, SREG
	
	; We invert the value of toggle and save it to toggle
	LDS R16, toggle
	LDI R17, 1
	EOR R16, R17
	STS toggle, R16

	LDS R16, toggle
	CPI R16, 0
	BREQ ISR_PUSH_BUTTON_tempUnit
	
ISR_PUSH_BUTTON_humUnit:
	LDI R16, 0b0111_0110
	STS quantityUnit, R16 
	RJMP ISR_PUSH_BUTTON_unitsDone

ISR_PUSH_BUTTON_tempUnit:
	LDI R16, 0b0011_1001
	STS quantityUnit, R16 

ISR_PUSH_BUTTON_unitsDone:

	; Now we change the quantity being displayed
	; I know its bad practice to call long routines inside of an ISR but this seems to work.
	; By doing this, we make device much more responsive to changes in the push button.
	; So when a user presses the push button, we immdeiately change the displayed value
	; and update the status LEDs. The alternative is to remove this code an update the displayed
	; quantity only when new data is fetched from the DHT22.
	; We are lucky though as none of the methods below use interrupts so they will work fine
	; even when interrupts are disabled inside the ISR.

	RCALL DIV_start ; Divide the measurement to be displayed by 10
	RCALL CVRT_start ; Convert the values into BCD
	RCALL LKP_start ; Convert the BCD values into bit patterns to display
	RCALL DHT_neg_led ; Turn on the negative temperature indicator LED if the temperature is below 0

	OUT SREG, R20

	POP R20
	POP R17
	POP R16
RETI

ISR_DHT_PIN_CHANGE:
	PUSH R16
	PUSH R20

	CLR R16
	CLR R20

	IN R20, SREG

	; Prevent PD0 (the pin that the DHT22 is connected to) from triggering an interrupt
	LDI R16, (0 << PCINT16)
	STS PCMSK2, R16

	OUT SREG, R20

	POP R20
	POP R16
RETI

ISR_WATCHDOG:
	; Turn on pins to show the error symbol "-"
	SBI PORTB, 6
	SBI DDRB, 6

	; Activate the transistors
	SBI PORTD, 4
	SBI DDRD, 4
	SBI PORTD, 5
	SBI DDRD, 5
	SBI PORTD, 6
	SBI DDRD, 6
	SBI PORTD, 7
	SBI DDRD, 7
	ISR_WATCHDOG_loop:
	RJMP ISR_WATCHDOG_loop
RETI

ISR_TIMER_2:
	PUSH R16
	PUSH R20

	CLR R16
	CLR R20

	IN R20, SREG

	; We turn off the timer
	LDI R16, tim2_stop
	STS TCCR2B, R16

	; Clear the timer's counter
	CLR R16
	STS TCNT2, R16

	OUT SREG, R20

	POP R20
	POP R16
RETI

init:
	; We set up the stack
	LDI R16, HIGH(RAMEND)
	OUT SPH, R16

	LDI R16, LOW(RAMEND)
	OUT SPL, R16

	; Setup timer/counter 2
	LDI R16, tim2_enable_ctc_mode
	STS TCCR2A, R16

	; Enable output compare match A interrupt
	LDI R16, tim2_enable_output_compare_match_A
	STS TIMSK2, R16

	; Setup sleep mode
	; We want to use the power save mode
	LDI R16, power_save_enable
	OUT SMCR, R16

	; Enable external interrupt int0 (on PD2)
	; This is for the push button. We want to trigger
	; an interrupt when the AVR detects a low level
	LDI R16, int0_enable
	OUT EIMSK, R16

	LDI R16, int0_level_sense
	STS EICRA, R16

	; Enable pin change interrupt on pcint2
	; This is for the DHT22
	LDI R16, pcint2_enable
	STS PCICR, R16

	; Specifically enable PD0 to trigger pcint2
	LDI R16, (1 << PCINT16)
	STS PCMSK2, R16

	; Initialise all of the variables in the data memory
	LDI R16, 0
	STS tempRawHigh, R16
	STS tempRawLow, R16
	STS humRawHigh, R16
	STS humRawLow, R16
	STS wholeNumber, R16
	STS remainder, R16
	STS negTemp, R16
	STS toggle, R16 ; Set the value of toggle to zero. Zero means we are displaying the temperature by default. One means we are displaying humidity

	; We setup the watchdog so that it will cause an interrupt if its not reset in time
	; We do this incase there is a fault with the sensor. This will stop the system
	; from hanging.
	LDI R16, enable_editing
	STS WDTCSR, R16

	; We now have four cycles to set the prescaler value which will cause the watchdog
	; to timeout after one second.
	LDI R16, set_prescaler_enable_interrupt_mode
	STS WDTCSR, R16

	; Set PC5 to act as an input
	; If this pin is connected to ground, the AVR will stop
	; the regular program, turn off all of the display pins
	; and then wait. We do this so that we can connect the ISP
	; programmer to the pins. I've done this because the ISP pins
	; are part of the pins that drive the display and I don't want to
	; damage my programmer by sending a voltage to it in the wrong direction.
	SBI PORTC, 5
	CBI DDRC, 5

	SEI

	; We set the displays to show "----" while the DHT22 gets data.
	; We do this so that the user knows the device is powered on.
	LDI R16, 0b0100_0000
	MOV R1, R16
	MOV R2, R16
	MOV R6, R16
	STS quantityUnit, R16

	RCALL DSP_init

	; This bit pattern will display the unit of the quantity being shown.
	; We set the bit patten to show the temperature unit "C" as this is the
	; default value to display.
	LDI R16, 0b0011_1001
	STS quantityUnit, R16

	CLR R17
	CLR R18

; When the program is running, most of its time is spent running these two loops.
; innerLoop runs 255 times, then it branches to outerLoop which causes its control register
; to increment by one, once its control register equals 255, the code to get new readings from
; the DHT22 is called. If you change the values by the CPI commands, you change how long the update
; interval is. If you make it too short, the DHT22 won't respond to the update requests as it
; needs at least 2 seconds in between requests.
innerLoop:
	WDR ; We must reset the watchdog so that we don't timeout and call the interrupt
	CPI R17, 255
	BREQ outerLoop
	RCALL DSP_init ; Refresh the display
	RCALL FLASH_mode ; Check if PC5 has been grounded
	INC R17
RJMP innerLoop

outerLoop:
	CLR R17
	CPI R18, 255
	BREQ update
	INC R18
RJMP innerLoop

update:
	; This subroutine is responsible for collecting new sensor readings.
	; It then converts these readings to the correct format for displaying
	CLR R17
	CLR R18

	RCALL DHT_start ; Get the values from DHT22
	RCALL DHT_neg_led ; Turn on the negative temperature indicator LED if the temperature is below zero
	RCALL DIV_start ; Divide one set of values by 10
	RCALL CVRT_start ; Convert the values into BCD
	RCALL LKP_start ; Convert the BCD values into bit patterns to display
RJMP innerLoop

FLASH_mode:
	PUSH R16
	PUSH R17

	IN R16, PINC
	ANDI R16, 0b0010_0000
	LDI R17, 0b0000_0000
	CPSE R16, R17
	CPSE R16, R16
	RCALL FLASH_loop

	POP R17
	POP R16
RET

FLASH_loop:
	WDR
	; Turn off the displays by setting pins to high impedance inputs
	CLR R16
	OUT DDRB, R16
	OUT PORTB, R16
RJMP FLASH_loop
RET

DHT_start:
	PUSH R16
	PUSH R17
	PUSH R21
	PUSH R22
	PUSH R23
	PUSH R24
	PUSH R25

	CLR R16
	CLR R17
	CLR R21
	CLR R22
	CLR R23
	CLR R24
	CLR R25

	; Before we do anything, we need to use a "lighter" sleep mode so that
	; the pin change interrupt can wake the AVR.
	LDI R16, idle_enable
	OUT SMCR, R16

	; To use one wire communication, we set PORT to zero and then manipulate DDR
	; Now that we have set port D to zero, we don't touch it!
	CBI PORTD, 0 

	/*STEP 1: Pull the bus low for 1ms*/
	; ### START OF HANDSHAKE ###
	; DDRD high and PORTD low = output low (sink)
	SBI DDRD, 0 

	; Setup timer for 1ms
	LDI R16, 125
	STS OCR2A, R16

	; We set a prescaler of 64 and start the timer
	LDI R16, tim2_start_with_prescaler_64
	STS TCCR2B, R16

	SLEEP

	/*STEP 2: Release the bus (i.e. it goes high) and wait for DHT22 to pull it low*/
	CBI DDRD, 0

	; Enable PD0 (the pin that DHT22 is connected to) to trigger an interrupt
	LDI R16, (1 << PCINT16)
	STS PCMSK2, R16

	SLEEP

	; Now, we must wait for DHT22 to release the bus (i.e. pull bus high)
	; Enable PD0 to trigger an interrupt
	LDI R16, (1 << PCINT16)
	STS PCMSK2, R16

	SLEEP

	; ### END OF HANDSHAKE ###
	; ### START OF TRANSMISSION LOOP###

	CLR R17

DHT_transmission:
		; Now we must wait for DHT22 to pull the bus low which is the start of data transmission
		; Enable PD0 to trigger an interrupt
		LDI R16, (1 << PCINT16)
		STS PCMSK2, R16

		SLEEP

	DHT_bypass_low:
		; Now we wait for DHT22 to pull the bus high
		; Enable PD0 to trigger an interrupt
		LDI R16, (1 << PCINT16)
		STS PCMSK2, R16

		SLEEP

		; Now we time 29 microseconds and go to sleep
		LDI R16, 29
		STS OCR2A, R16
		; We set a prescaler of 8 and start the timer
		LDI R16, tim2_start_with_prescaler_8
		STS TCCR2B, R16

		SLEEP

		; Now we check the value of bit 0 in PIND.
		; If it is a one, then we have received a "1" from the DHT22
		; If it is a zero, then we have received a "0" from the DHT22
		SBIC PIND, 0 ; If bit 0 in PIND is zero, skip the next instruction
		RJMP DHT_one
		RJMP DHT_zero

	DHT_one:
		INC R17 ; This is the roll counter. We need to do 40 rolls

		SEC  ; We set carry flag and rotate it into bit 0
		ROL R21 ; Parity byte. This code doesn't use the parity btye to check the received data
		ROL R22 ; Temp decimal
		ROL R23 ; Temp int
		ROL R24 ; Humidity decimal
		ROL R25 ; Humidity int

		; If 40 rolls have been done, break out of the loop
		CPI R17, 40
		BREQ DHT_transmission_done
	RJMP DHT_transmission

	DHT_zero:
		INC R17 ; This is the roll counter. We need to do 40 rolls

		CLC ; We clear carry flag and rotate it into bit 0
		ROL R21 ; Parity byte. This code doesn't use the parity btye to check the received data
		ROL R22 ; Temp decimal
		ROL R23 ; Temp int
		ROL R24 ; Humidity decimal
		ROL R25 ; Humidity int

		; If 40 rolls have been done, break out of the loop
		CPI R17, 40
		BREQ DHT_transmission_done
	RJMP DHT_bypass_low

	; ### END OF TRANSMISSION LOOP ###

DHT_transmission_done:
	; Now we must sleep until DHT22 releases the bus (i.e. bus goes high)
	; Enable PD0 to trigger an interrupt
	LDI R16, (1 << PCINT16)
	STS PCMSK2, R16

	SLEEP

	; Now we check that data we received against its checksum.
	; temp high + temp low + hum high + hum low = checksum
	MOV R16, R25
	ADD R16, R24
	ADD R16, R23
	ADD R16, R22

	; If they are eqaul, then the data is valid and not corrupt
	; If the data is corrupt, skip and don't store it. We will
	; just display the previous measurement.
	CP R16, R21
	BRNE DHT_corrupt

	; When DHT22 measures a negative temperature, the MSB of the 16 temperature bits is set to one
	; So we need to store this value so we can use it to turn on our LED to say the temperature
	; is negative. But we must remove it from the temperature reading because it will mess with
	; my conversion code later on. If the value is not negative, then this code will just set
	; negTemp to zero.
	BST R23, 7 ; Store bit seven of R23 in the T flag	
	ANDI R23, 0b0111_1111 ; Clear bit seven in R23	
	BLD R16, 0 ; Store the T flag in bit 0 of R16
	STS negTemp, R16 ; Store R16 in negTemp

	; We store the raw temperature value in rawHigh (upper byte) and rawLow (lower byte)
	STS tempRawHigh, R23
	STS tempRawLow, R22

	; We store the raw humidity value in rawHigh (upper byte) and rawLow (lower byte)
	STS humRawHigh, R25
	STS humRawLow, R24

	DHT_corrupt:

	; Now that we are done with the DHT, we can use a "deeper" sleep mode
	LDI R16, power_save_enable
	OUT SMCR, R16

	POP R25
	POP R24
	POP R23
	POP R22
	POP R21
	POP R17
	POP R16
RET

DHT_neg_led:
	PUSH R16

	CLR R16

	; Turn off the LED
	CBI PORTD, 3
	CBI DDRD, 3

	; First we make sure we aren't displaying humidity
	; If we are displaying humidity, skip the rest of the
	; method because we don't have negative humidities.
	; Remember, if toggle is a zero, we are displaying temperature and
	; if toggle is a one, we are displaying humidity.
	LDS R16, toggle
	CPI R16, 1
	BREQ DHT_neg_led_done

	LDS R16, negTemp
	SBRS R16, 0 ; If bit 0 in the register isn't set, then the temperature isn't below zero, so call DHT_neg_led_done
	RJMP DHT_neg_led_done
	
	; Turn on the LED
	SBI PORTD, 3
	SBI DDRD, 3

DHT_neg_led_done:
	POP R16
RET

; This method takes a 16 bit number (stored in a pair of registers) and divides it by ten
DIV_start:
	PUSH R16 
	PUSH R17 
	PUSH R18 
	PUSH R19
	PUSH R20
	PUSH R21 

	CLR R16
	CLR R17
	CLR R18
	CLR R19
	CLR R20
	CLR R21
	
	; These three lines check the value of toggle and chose what
	; measurement will be converted and ultimately end up being displayed.
	; If toggle is zero, then temperature will eventually be displayed.
	; If toggle is one, then humidity will eventually be displayed.
	LDS R16, toggle
	CPI R16, 0
	BREQ DIV_convertTemperature

	DIV_convertHumidity:
		; R20 contains the whole number, R18 contains the remainder
		LDS R17, humRawHigh ; MSB 16-bit-number to be divided
		LDS R16, humRawLow ; LSB 16-bit-number to be divided
		RJMP DIV

	DIV_convertTemperature:
		; R20 contains the whole number, R18 contains the remainder
		LDS R17, tempRawHigh ; MSB 16-bit-number to be divided
		LDS R16, tempRawLow ; LSB 16-bit-number to be divided

		; ##################################################
		; This method is modified from the original which is 
		; Copyright (C) 2000-2020 Gerhard Schmidt, Kastanienallee 20, D-64289 Darmstad/Germany
		DIV:
			INC R20
		DIVA:
			CLC  
			ROL R16 
			ROL R17 
			ROL R18
			BRCS DIVB
			CPI R18, 10
			BRCS DIVC
		DIVB:
			SUBI R18, 10
			SEC
			RJMP DIVD
		DIVC:
			CLC
		DIVD:
			ROL R20 
			ROL R21
			BRCC DIVA
		; ##################################################
DIV_done:
	; Store the divided measurement in wholeNumber and the remainder in remainder
	STS wholeNumber, R20
	STS remainder, R18

	POP R21
	POP R20
	POP R19
	POP R18
	POP R17
	POP R16
RET

; This subroutine splits any number between 0 and 99 into individual digits.
; This is done by repetedly subtracting 10 (from the number) until it is less than ten.
; Then the subroutine repetedly subtracts 1 from the number until it is equal to zero.
; While these subtractions are being performed, counters are increased each time a subtraction is done.
; By doing this, we get the value of the tens digit and the units ditgit.
; Once this is done, the two results are packaged into R1. The upper nibble is the tens digit
; and the lower nibble is the units digit.
CVRT_start:
	PUSH R16
	PUSH R17
	PUSH R18
	PUSH R19

	CLR R16
	CLR R17
	CLR R18
	CLR R19

	LDS R16, wholeNumber

CVRT_getTens:
	CPI R16, 10
	BRLO CVRT_getUnits
	SUBI R16, 10
	INC R18
	RJMP CVRT_getTens

CVRT_getUnits:
	CPI R16, 0
	BREQ CVRT_done
	SUBI R16, 1
	INC R17
	RJMP CVRT_getUnits

CVRT_done:
	SWAP R18 ; We perform a swap so that the tens digit is stored in the upper nibble.
	ADD R18, R17
	MOV R1, R18 ; We package the tens and units digits together. The tens digit is in the upper nibble and the units digit is in the lower nibble.

	POP R19
	POP R18
	POP R17
	POP R16
RET

; **** Convert the temperature/humidity value into bitpatterns that can be displayed on 7 segment displays ****
LKP_start:
	PUSH ZH
	PUSH ZL
	PUSH R17
	PUSH R16
	PUSH R4
	PUSH R3

	CLR ZH
	CLR ZL
	CLR R17
	CLR R16
	CLR R4
	CLR R3

	; We make a copy of R1 (to use later on) because it will be overwritten in the next few lines.
	MOV R4, R1

	; Get the bitpattern for the tens digit and store it in R1.
	MOV R16, R1
	ANDI R16, 0b1111_0000

	; We move the tens digit to the lower nibble
	SWAP R16

	CALL LKP_getBitPattern
	MOV R1, R3

	; Get the bitpattern for the units digit and store it in R2.
	MOV R16, R4
	ANDI R16, 0b0000_1111

	CALL LKP_getBitPattern
	MOV R2, R3

	; Get the bitpattern for the remainder digit and store it in R6
	LDS R16, remainder
	CALL LKP_getBitPattern
	MOV R6, R3

	POP R3
	POP R4
	POP R16
	POP R17
	POP ZL
	POP ZH
RET

; These three subroutines take the value in R16 and find its corresponding bitpatten in the lookup table
; at the bottom of this program. It saves the result to R3.
LKP_getBitPattern:
	LDI ZH, HIGH(2 * LOOK_UP_TABLE) ; ZH is stored in R31.
	LDI ZL, LOW(2 * LOOK_UP_TABLE) ; ZL is stored in R30.

	CLR R3
	ADD ZL, R16 ; We add the number we want to lookup to the Z register. This will position the Z register to the corresponding bitpattern.
	ADC ZH, R3
	LPM R3, Z ; Store the result of the lookup in R3.
RET

; **** Take the bitpatterns and save them to the port registers so we can display the reading ****
DSP_init:
	PUSH R16
	PUSH R17

	CLR R16
	CLR R17

	; We will use a part of port D to supply 5V to the base of the NPN transistors. This turns the transistors "on" which grounds the corresponding display.
	IN R16, PORTD
	ANDI R16, 0b0000_1111
	OUT PORTD, R16

	; DDR register must always be set to high so that this combined with a one or zero in the port register will set the pin to high or low, respectively.
	IN R16, DDRD
	ANDI R16, 0b0000_1111
	ORI R16, 0b1111_0000
	OUT DDRD, R16

; We assign values to the port which will turn on the appropriate segments on the 7 segment displays.
DSP_start:
    ; Set segment one to display the tens digit
	MOV R17, R1 ; This is the digit we want to display
	LDI R16, 0b0001_0000 ; We want to ground display one
	RCALL DSP_display

	; Set segment two to display the units digit
	MOV R17, R2
	LDI R16, 0b0010_0000 ; We want to ground display two

	; Before we display the number, we need to turn on the
	; decimal point.
	ORI R17, 0b1000_0000
	RCALL DSP_display

	; Set segment three to display the remainder digit
	MOV R17, R6
	LDI R16, 0b0100_0000 ; We want to ground display three
	RCALL DSP_display

	; Set segment four to display the unit of the quantity being displayed
	LDS R17, quantityUnit
	LDI R16, 0b1000_0000 ; We want to ground display four
	RCALL DSP_display

	POP R17
	POP R16
RET

DSP_display:
	; We use the same register for both instructions because we want to set the pin to output and set the value to high
	OUT PORTB, R17 ; We set some pins of PORTB to output
	OUT DDRB, R17 ; We set some pins in DDRB to high

	; We musn't change the whole of PORTD because other things are connected to it besides the transistors.
	; We must only change PD4, PD5, PD6 and PD7.
	IN R17, PORTD
	ANDI R17, 0b0000_1111
	ADD R16, R17
	OUT PORTD, R16 ; We set one of the pins to high in PORTD so that we can turn on a transistor which will connect one of the displays to ground.
	
	; We need to sleep for a little bit (2.5 microseconds) so that the transistor has time to turn on.
	LDI R16, 20
	STS OCR2A, R16

	; We set a prescaler of one and start the timer
	LDI R16, time2_start_with_prescaler_1
	STS TCCR2B, R16

	SLEEP
	
	; Next we need to set all of the pins driving the displays to zero so we are ready to display the next value.
	CLR R17

	OUT PORTB, R17
	OUT DDRB, R17 

	; We musn't change the whole of PORTD because other things are connected to it besides the transistors.
	; We must only change PD4, PD5, PD6 and PD7.
	IN R17, PORTD
	ANDI R17, 0b0000_1111
	OUT PORTD, R17 ; We set one of the pins to low in PORTD so that we can turn off a transistor which will disconnect one of the displays from ground.

	; We need to sleep for a little bit (3.5 microseconds) so that the transistor has time to turn off.
	LDI R16, 28
	STS OCR2A, R16

	; We set a prescaler of one and start the timer
	LDI R16, time2_start_with_prescaler_1
	STS TCCR2B, R16

	SLEEP
RET

; The lookup table below is used to convert a number into a corresponding binary value that turns on the appropriate segments of the seven segment displays.
; The first value on the left is for the number zero, the last value on the right is for the number nine.
LOOK_UP_TABLE:
.DB 0b00111111, 0b00000110, 0b01011011, 0b01001111, 0b01100110, 0b01101101, 0b01111101, 0b00000111, 0b01111111, 0b01101111
