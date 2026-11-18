-------------------------------------------------------------------------------
-- led_toggle.vhd -- Toggle an output on every press of a (debounced) button
--
-- A rising-edge detector turns each press into a one-cycle pulse, and the
-- pulse flips the LED. The input MUST come from the debouncer: a bouncing
-- button would produce several edges per press and the LED would toggle a
-- random number of times.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity led_toggle is
    port (
        clk : in  std_logic;
        rst : in  std_logic;
        btn : in  std_logic;    -- clean, synchronous (from debouncer)
        led : out std_logic
    );
end entity led_toggle;

architecture rtl of led_toggle is
    signal btn_prev : std_logic := '0';
    signal state    : std_logic := '0';
begin
    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                btn_prev <= '0';
                state    <= '0';
            else
                btn_prev <= btn;
                if btn = '1' and btn_prev = '0' then   -- press (rising edge)
                    state <= not state;
                end if;
            end if;
        end if;
    end process;

    led <= state;
end architecture rtl;
