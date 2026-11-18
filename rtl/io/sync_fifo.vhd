-------------------------------------------------------------------------------
-- sync_fifo.vhd -- Small synchronous FIFO (first-word fall-through)
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sync_fifo is
    generic (
        WIDTH      : natural := 8;
        DEPTH_BITS : natural := 4           -- 16 entries
    );
    port (
        clk   : in  std_logic;
        rst   : in  std_logic;
        wr_en : in  std_logic;
        wdata : in  std_logic_vector(WIDTH - 1 downto 0);
        rd_en : in  std_logic;
        rdata : out std_logic_vector(WIDTH - 1 downto 0);
        empty : out std_logic;
        full  : out std_logic
    );
end entity sync_fifo;

architecture rtl of sync_fifo is
    type mem_t is array (0 to 2 ** DEPTH_BITS - 1) of std_logic_vector(WIDTH - 1 downto 0);
    signal mem    : mem_t := (others => (others => '0'));
    signal wr_ptr : unsigned(DEPTH_BITS downto 0) := (others => '0');
    signal rd_ptr : unsigned(DEPTH_BITS downto 0) := (others => '0');
    signal empty_i, full_i : std_logic;
begin
    empty_i <= '1' when wr_ptr = rd_ptr else '0';
    full_i  <= '1' when wr_ptr(DEPTH_BITS) /= rd_ptr(DEPTH_BITS) and
                        wr_ptr(DEPTH_BITS - 1 downto 0) = rd_ptr(DEPTH_BITS - 1 downto 0)
               else '0';
    empty <= empty_i;
    full  <= full_i;
    rdata <= mem(to_integer(rd_ptr(DEPTH_BITS - 1 downto 0)));

    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                wr_ptr <= (others => '0');
                rd_ptr <= (others => '0');
            else
                if wr_en = '1' and full_i = '0' then
                    mem(to_integer(wr_ptr(DEPTH_BITS - 1 downto 0))) <= wdata;
                    wr_ptr <= wr_ptr + 1;
                end if;
                if rd_en = '1' and empty_i = '0' then
                    rd_ptr <= rd_ptr + 1;
                end if;
            end if;
        end if;
    end process;
end architecture rtl;
