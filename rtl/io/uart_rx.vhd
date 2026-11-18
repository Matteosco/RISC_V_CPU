-------------------------------------------------------------------------------
-- uart_rx.vhd -- UART receiver, 8N1
--
-- * The line is synchronised with two flip-flops (it is asynchronous).
-- * A falling edge starts a frame; the start bit is checked again in its
--   middle, so a glitch shorter than half a bit is ignored.
-- * Each data bit is sampled in the middle of its bit time.
-- * valid pulses for one cycle with the received byte; frame_err is set
--   instead when the stop bit is not '1' (wrong baud rate or wiring).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_rx is
    generic (
        CLKS_PER_BIT : positive := 434     -- 50 MHz / 115200
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        rx        : in  std_logic;          -- serial input (idle = '1')
        data      : out std_logic_vector(7 downto 0);
        valid     : out std_logic;          -- one-cycle pulse: byte received
        frame_err : out std_logic;          -- one-cycle pulse: bad stop bit
        -- debug (ILA): the synchronised line, the state and the bit number
        dbg_rx    : out std_logic;
        dbg_state : out std_logic_vector(1 downto 0);   -- 00 IDLE 01 START 10 DATA 11 STOP
        dbg_bit   : out std_logic_vector(2 downto 0)
    );
end entity uart_rx;

architecture rtl of uart_rx is
    type state_t is (IDLE, START, DATA_BITS, STOP);
    signal state    : state_t := IDLE;
    signal rx_s1, rx_s2 : std_logic := '1';
    signal clk_cnt  : natural range 0 to CLKS_PER_BIT - 1 := 0;
    signal bit_idx  : natural range 0 to 7 := 0;
    signal shreg    : std_logic_vector(7 downto 0) := (others => '0');
begin
    process (clk)
    begin
        if rising_edge(clk) then
            rx_s1 <= rx;                    -- 2-FF synchroniser
            rx_s2 <= rx_s1;
            valid     <= '0';
            frame_err <= '0';

            if rst = '1' then
                state   <= IDLE;
                clk_cnt <= 0;
                bit_idx <= 0;
            else
                case state is
                    when IDLE =>
                        clk_cnt <= 0;
                        bit_idx <= 0;
                        if rx_s2 = '0' then             -- falling edge: start bit
                            state <= START;
                        end if;

                    when START =>                       -- wait half a bit
                        if clk_cnt = CLKS_PER_BIT / 2 - 1 then
                            clk_cnt <= 0;
                            if rx_s2 = '0' then
                                state <= DATA_BITS;     -- real start bit
                            else
                                state <= IDLE;          -- glitch: ignore
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    when DATA_BITS =>                   -- sample in mid-bit
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            shreg   <= rx_s2 & shreg(7 downto 1);   -- LSB first
                            if bit_idx = 7 then
                                state <= STOP;
                            else
                                bit_idx <= bit_idx + 1;
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    when STOP =>
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            state   <= IDLE;
                            if rx_s2 = '1' then
                                valid <= '1';
                            else
                                frame_err <= '1';
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;

    data <= shreg;

    dbg_rx    <= rx_s2;
    dbg_state <= "00" when state = IDLE  else
                 "01" when state = START else
                 "10" when state = DATA_BITS else "11";
    dbg_bit   <= std_logic_vector(to_unsigned(bit_idx, 3));
end architecture rtl;
