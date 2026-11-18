-------------------------------------------------------------------------------
-- uart_tx.vhd -- UART transmitter, 8N1
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is
    generic (
        CLKS_PER_BIT : positive := 434     -- 50 MHz / 115200
    );
    port (
        clk   : in  std_logic;
        rst   : in  std_logic;
        start : in  std_logic;             -- load data and begin (when idle)
        data  : in  std_logic_vector(7 downto 0);
        busy  : out std_logic;
        tx    : out std_logic
    );
end entity uart_tx;

architecture rtl of uart_tx is
    signal shreg   : std_logic_vector(9 downto 0) := (others => '1');
    signal bit_cnt : natural range 0 to 10 := 0;
    signal clk_cnt : natural range 0 to CLKS_PER_BIT - 1 := 0;
    signal busy_i  : std_logic := '0';
begin
    busy <= busy_i;
    tx   <= shreg(0) when busy_i = '1' else '1';

    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                busy_i  <= '0';
                bit_cnt <= 0;
                clk_cnt <= 0;
                shreg   <= (others => '1');
            elsif busy_i = '0' then
                if start = '1' then
                    shreg   <= '1' & data & '0';  -- stop, data (LSB first), start
                    busy_i  <= '1';
                    bit_cnt <= 0;
                    clk_cnt <= 0;
                end if;
            else
                if clk_cnt = CLKS_PER_BIT - 1 then
                    clk_cnt <= 0;
                    shreg   <= '1' & shreg(9 downto 1);
                    if bit_cnt = 9 then
                        busy_i <= '0';
                    else
                        bit_cnt <= bit_cnt + 1;
                    end if;
                else
                    clk_cnt <= clk_cnt + 1;
                end if;
            end if;
        end if;
    end process;
end architecture rtl;
