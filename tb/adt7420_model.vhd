-------------------------------------------------------------------------------
-- adt7420_model.vhd -- simulation model of the ADT7420 temperature sensor
--                      (I2C slave, simulation only)
--
-- Enough of the real chip for the tests:
--   * I2C address ADDR (0x4B on the Nexys A7), open-drain SDA
--   * a register pointer, set by the first byte written after the address
--   * registers 0x00/0x01 temperature MSB/LSB (TEMP_RAW), 0x02 status,
--     0x03 configuration, 0x0B ID = 0xCB; reads auto-increment the pointer
--   * after power-up the pointer is 0x00: a plain 2-byte read returns the
--     temperature, as on the real sensor
-- The bus lines must have pull-ups ('H') in the testbench.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity adt7420_model is
    generic (
        ADDR     : std_logic_vector(6 downto 0)  := "1001011";   -- 0x4B
        TEMP_RAW : std_logic_vector(15 downto 0) := x"0C48"      -- 24.5625 C
    );
    port (
        scl : in    std_logic;
        sda : inout std_logic := 'Z'   -- open drain: released at start
    );
end entity adt7420_model;

architecture sim of adt7420_model is
begin
    process (scl, sda)
        type phase_t is (IDLE, RX, RX_ACK, TX, TX_ACK);
        variable ph       : phase_t := IDLE;
        variable cnt      : natural range 0 to 8 := 0;
        variable sh       : std_logic_vector(7 downto 0) := (others => '0');
        variable is_addr  : boolean := false;
        variable rw       : std_logic := '0';
        variable ptr      : unsigned(7 downto 0) := x"00";
        variable mack     : std_logic := '1';
        variable scl_prev : std_logic := '1';
        variable sda_prev : std_logic := '1';
        variable scl_now, sda_now : std_logic;

        impure function reg(p : unsigned(7 downto 0)) return std_logic_vector is
        begin
            case to_integer(p) is
                when 16#00# => return TEMP_RAW(15 downto 8);
                when 16#01# => return TEMP_RAW(7 downto 0);
                when 16#02# => return x"00";
                when 16#03# => return x"00";
                when 16#0B# => return x"CB";
                when others => return x"00";
            end case;
        end function;

        procedure drive(b : std_logic) is
        begin
            if b = '0' then sda <= '0'; else sda <= 'Z'; end if;
        end procedure;
    begin
        scl_now := to_X01(scl);
        sda_now := to_X01(sda);

        if scl_now = '1' and scl_prev = '1' and sda_now /= sda_prev then
            -- SDA changes while SCL is high: START or STOP
            if sda_now = '0' then              -- START (or repeated START)
                ph := RX; cnt := 0; is_addr := true;
            else                               -- STOP
                ph := IDLE;
            end if;
            sda <= 'Z';

        elsif scl_now = '1' and scl_prev = '0' then          -- SCL rising: sample
            case ph is
                when RX     => sh := sh(6 downto 0) & sda_now; cnt := cnt + 1;
                when TX_ACK => mack := sda_now;
                when others => null;
            end case;

        elsif scl_now = '0' and scl_prev = '1' then          -- SCL falling: drive
            case ph is
                when RX =>
                    if cnt = 8 then
                        if is_addr then
                            if sh(7 downto 1) = ADDR then
                                rw := sh(0);
                                drive('0');                  -- ACK the address
                                ph := RX_ACK;
                            else
                                ph := IDLE;                  -- not us
                            end if;
                        else
                            ptr := unsigned(sh);             -- pointer register
                            drive('0');
                            ph := RX_ACK;
                        end if;
                    end if;
                when RX_ACK =>                               -- end of our ACK bit
                    if is_addr and rw = '1' then             -- read: send a byte
                        sh := reg(ptr);
                        drive(sh(7));
                        cnt := 1;
                        ph := TX;
                    else
                        sda <= 'Z';
                        cnt := 0;
                        ph := RX;
                    end if;
                    is_addr := false;
                when TX =>
                    if cnt = 8 then
                        sda <= 'Z';                          -- master sends ACK/NACK
                        ph := TX_ACK;
                    else
                        drive(sh(7 - cnt));
                        cnt := cnt + 1;
                    end if;
                when TX_ACK =>
                    if mack = '0' then                       -- ACK: next register
                        ptr := ptr + 1;
                        sh := reg(ptr);
                        drive(sh(7));
                        cnt := 1;
                        ph := TX;
                    else                                     -- NACK: done
                        sda <= 'Z';
                        ph := IDLE;
                    end if;
                when IDLE => null;
            end case;
        end if;

        scl_prev := scl_now;
        sda_prev := sda_now;
    end process;
end architecture sim;
