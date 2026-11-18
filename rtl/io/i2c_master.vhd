-------------------------------------------------------------------------------
-- i2c_master.vhd -- byte-level I2C master (100 kHz), used for the ADT7420
--                   temperature sensor of the Nexys A7
--
-- The CPU drives it through io_ctrl, one command at a time:
--   cmd bit0 START    (repeated) start condition
--   cmd bit1 WRITE    send tx_byte, then read the ACK bit of the slave
--   cmd bit2 READ     receive a byte into rx_byte, then send ACK
--   cmd bit3 STOP     stop condition
--   cmd bit4 NACK     with READ: answer NACK instead of ACK (last byte)
-- The parts of one command run in the order START, WRITE or READ, STOP.
-- busy = 1 while a command runs; nack = 1 if the slave did not acknowledge
-- the last byte written.
--
-- Timing (NXP I2C-bus specification UM10204 rev. 7.0, Table 11,
-- Standard-mode): every bit is split into 4 quarters of QUARTER clock cycles
-- (50 MHz / (4 x 125) = 100 kHz, 2.5 us per quarter). The action of a
-- quarter happens at its end:
--   end of q0: SCL low, put the bit on SDA     (quarters 0, 1: SCL low  5.0 us)
--   end of q1: SCL high                        (quarters 2, 3: SCL high 5.0 us)
--   end of q2: sample SDA (middle of SCL high)
--   end of q3: SCL low
-- START: SDA falls while SCL is high; STOP: SDA rises while SCL is high.
-- START and STOP use 6 quarters, so that every set-up / hold time is two
-- quarters = 5.0 us: tSU;STA >= 4.7 us, tHD;STA >= 4.0 us, tSU;STO >= 4.0 us
-- (tb/i2c_timing_check.vhd checks all the Table 11 times in simulation).
-- If a slave holds SCL low after it is released (clock stretching), the
-- master waits.
--
-- The bus is open drain: scl_o / sda_o = '0' pulls the line low, '1'
-- releases it (pull-up resistors make it high).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity i2c_master is
    generic (
        QUARTER : positive := 125            -- clock cycles per quarter bit
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        cmd_valid : in  std_logic;           -- start a command (ignored if busy)
        cmd       : in  std_logic_vector(4 downto 0);
        tx_byte   : in  std_logic_vector(7 downto 0);
        rx_byte   : out std_logic_vector(7 downto 0);
        busy      : out std_logic;
        nack      : out std_logic;
        scl_o     : out std_logic;           -- '0' = pull low, '1' = release
        sda_o     : out std_logic;
        scl_i     : in  std_logic;
        sda_i     : in  std_logic
    );
end entity i2c_master;

architecture rtl of i2c_master is
    type state_t is (IDLE, S_START, S_BYTE, S_STOP);
    signal state   : state_t := IDLE;
    signal tick    : natural range 0 to QUARTER - 1 := 0;
    signal q       : natural range 0 to 5 := 0;          -- quarter (START/STOP: 0..5)
    signal bitn    : natural range 0 to 8 := 0;          -- 0..7 data, 8 = ACK
    signal shreg   : std_logic_vector(7 downto 0) := (others => '0');
    signal cmd_r   : std_logic_vector(4 downto 0) := (others => '0');
    signal scl_r   : std_logic := '1';
    signal sda_r   : std_logic := '1';
    signal rx_r    : std_logic_vector(7 downto 0) := (others => '0');
    signal nack_r  : std_logic := '0';
    signal reading : std_logic := '0';
    signal scl_s, sda_s : std_logic_vector(1 downto 0) := "11";   -- synchronisers
    signal scl_in, sda_in : std_logic;

    constant C_START : natural := 0;
    constant C_WRITE : natural := 1;
    constant C_READ  : natural := 2;
    constant C_STOP  : natural := 3;
    constant C_NACK  : natural := 4;
begin
    -- the bus lines come from outside: two flip-flops against metastability
    process (clk)
    begin
        if rising_edge(clk) then
            scl_s <= scl_s(0) & scl_i;
            sda_s <= sda_s(0) & sda_i;
        end if;
    end process;
    scl_in <= scl_s(1);
    sda_in <= sda_s(1);

    process (clk)
        -- after one part of the command, go to the next one
        procedure next_part(after_start : boolean) is
        begin
            q <= 0;
            if after_start and (cmd_r(C_WRITE) = '1' or cmd_r(C_READ) = '1') then
                state   <= S_BYTE;
                bitn    <= 0;
                reading <= cmd_r(C_READ);
            elsif cmd_r(C_STOP) = '1' then
                state <= S_STOP;
            else
                state <= IDLE;
            end if;
        end procedure;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
                scl_r <= '1';
                sda_r <= '1';
                nack_r <= '0';
            elsif state = IDLE then
                tick <= 0;
                q    <= 0;
                if cmd_valid = '1' and cmd(3 downto 0) /= "0000" then
                    cmd_r <= cmd;
                    shreg <= tx_byte;
                    if cmd(C_START) = '1' then
                        state <= S_START;
                    elsif cmd(C_WRITE) = '1' or cmd(C_READ) = '1' then
                        state   <= S_BYTE;
                        bitn    <= 0;
                        reading <= cmd(C_READ);
                    else
                        state <= S_STOP;
                    end if;
                end if;
            elsif tick /= QUARTER - 1 then
                -- clock stretching: SCL was released at the end of q1; while a
                -- slave still holds it low, quarter 2 does not advance
                if not (q = 2 and scl_in = '0') then
                    tick <= tick + 1;
                end if;
            else
                tick <= 0;
                case state is
                    when S_START =>             -- SDA high, SCL high, SDA low, SCL low
                        case q is                   -- (SCL is low here after a byte,
                                                    --  high when the bus is idle)
                            when 0 => sda_r <= '1'; q <= 1;           -- release SDA (SCL low or idle)
                            when 1 => scl_r <= '1'; q <= 2;           -- SCL high
                            when 2 => q <= 3;                         -- tSU;STA: 2 quarters
                            when 3 => sda_r <= '0'; q <= 4;           -- START
                            when 4 => q <= 5;                         -- tHD;STA: 2 quarters
                            when others => scl_r <= '0'; next_part(true);
                        end case;

                    when S_BYTE =>
                        case q is
                            when 0 =>
                                scl_r <= '0';
                                if bitn < 8 then        -- data bit
                                    sda_r <= shreg(7) or reading;        -- reading: release
                                else                    -- ACK bit
                                    if reading = '1' then
                                        sda_r <= cmd_r(C_NACK);          -- 0 = ACK, 1 = NACK
                                    else
                                        sda_r <= '1';                    -- slave answers
                                    end if;
                                end if;
                                q <= 1;
                            when 1 => scl_r <= '1'; q <= 2;
                            when 2 =>                   -- middle of SCL high: sample
                                if bitn < 8 then
                                    shreg <= shreg(6 downto 0) & sda_in;
                                elsif reading = '0' then
                                    nack_r <= sda_in;
                                end if;
                                q <= 3;
                            when others =>
                                scl_r <= '0';
                                if bitn = 8 then
                                    if reading = '1' then
                                        rx_r <= shreg;
                                    end if;
                                    next_part(false);
                                else
                                    bitn <= bitn + 1;
                                    q    <= 0;
                                end if;
                        end case;

                    when S_STOP =>              -- SDA low, SCL high, SDA high
                        case q is
                            when 0 => scl_r <= '0'; sda_r <= '0'; q <= 1;   -- SDA low (SCL low)
                            when 1 => scl_r <= '1'; q <= 2;           -- SCL high
                            when 2 => q <= 3;                         -- tSU;STO: 2 quarters
                            when 3 => sda_r <= '1'; q <= 4;           -- STOP
                            when 4 => q <= 5;                         -- bus free (tBUF)
                            when others => state <= IDLE; q <= 0;
                        end case;

                    when IDLE => null;
                end case;
            end if;
        end if;
    end process;

    busy    <= '0' when state = IDLE else '1';
    nack    <= nack_r;
    rx_byte <= rx_r;
    scl_o   <= scl_r;
    sda_o   <= sda_r;
end architecture rtl;
