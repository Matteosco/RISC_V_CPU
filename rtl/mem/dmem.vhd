-------------------------------------------------------------------------------
-- dmem.vhd -- Data memory: single-port Block RAM with byte write enables
--
-- Read-first behaviour; read data appears one cycle after the request
-- (during the MEM stage of the core). Initialised from a hex file so that
-- .data/.rodata produced by the assembler or C compiler is preloaded.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.riscv_pkg.all;

entity dmem is
    generic (
        ADDR_BITS : natural := 12;          -- words: 2**12 = 4096 (16 KiB)
        INIT_FILE : string  := "dmem.hex"
    );
    port (
        clk   : in  std_logic;
        en    : in  std_logic;
        we    : in  std_logic_vector(3 downto 0);  -- byte write enables
        addr  : in  word_t;                        -- byte address
        wdata : in  word_t;
        rdata : out word_t
    );
end entity dmem;

architecture rtl of dmem is
    constant DEPTH : natural := 2 ** ADDR_BITS;
    signal ram : word_array_t(0 to DEPTH - 1) := load_hex(INIT_FILE, DEPTH);
    attribute ram_style : string;
    attribute ram_style of ram : signal is "block";
begin
    process (clk)
        variable idx : natural range 0 to DEPTH - 1;
    begin
        if rising_edge(clk) then
            if en = '1' then
                idx   := to_integer(unsigned(addr(ADDR_BITS + 1 downto 2)));
                rdata <= ram(idx);
                for i in 0 to 3 loop
                    if we(i) = '1' then
                        ram(idx)(8 * i + 7 downto 8 * i) <= wdata(8 * i + 7 downto 8 * i);
                    end if;
                end loop;
            end if;
        end if;
    end process;
end architecture rtl;
