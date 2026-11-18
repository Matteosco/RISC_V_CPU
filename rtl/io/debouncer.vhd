-------------------------------------------------------------------------------
-- debouncer.vhd -- Synchroniser + debouncer for mechanical push buttons
--
-- Each input bit is first synchronised with two flip-flops (it is
-- asynchronous to the clock), then its output only changes after the
-- synchronised input has been *different* from the current output for
-- STABLE_CYCLES consecutive clock cycles. Any bounce shorter than that
-- restarts the count and never reaches the output.
--
--   STABLE_CYCLES = f_clk * t_debounce   (e.g. 50 MHz * 10 ms = 500 000)
--
-- Latency from a clean edge to the output: STABLE_CYCLES + 2 cycles.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity debouncer is
    generic (
        WIDTH         : positive := 5;
        STABLE_CYCLES : positive := 500_000
    );
    port (
        clk  : in  std_logic;
        rst  : in  std_logic;
        din  : in  std_logic_vector(WIDTH - 1 downto 0);   -- raw, asynchronous
        dout : out std_logic_vector(WIDTH - 1 downto 0)    -- clean, synchronous
    );
end entity debouncer;

architecture rtl of debouncer is
    type cnt_array_t is array (0 to WIDTH - 1) of natural range 0 to STABLE_CYCLES - 1;

    signal sync1, sync2 : std_logic_vector(WIDTH - 1 downto 0) := (others => '0');
    signal state        : std_logic_vector(WIDTH - 1 downto 0) := (others => '0');
    signal cnt          : cnt_array_t := (others => 0);
begin
    process (clk)
    begin
        if rising_edge(clk) then
            -- 2-FF synchroniser (not reset: it only samples)
            sync1 <= din;
            sync2 <= sync1;

            if rst = '1' then
                state <= (others => '0');
                cnt   <= (others => 0);
            else
                for i in 0 to WIDTH - 1 loop
                    if sync2(i) = state(i) then
                        cnt(i) <= 0;                    -- input agrees: nothing pending
                    elsif cnt(i) = STABLE_CYCLES - 1 then
                        state(i) <= sync2(i);           -- stable long enough: accept
                        cnt(i)   <= 0;
                    else
                        cnt(i) <= cnt(i) + 1;           -- still counting
                    end if;
                end loop;
            end if;
        end if;
    end process;

    dout <= state;
end architecture rtl;
