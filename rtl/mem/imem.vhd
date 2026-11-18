-------------------------------------------------------------------------------
-- imem.vhd -- Instruction memory (synchronous-read ROM -> Block RAM)
--
-- Initialised at elaboration from a hex file (one word per line).
-- The address is registered on the clock edge, so the core drives the
-- *next* PC and gets the current instruction back during IF.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.riscv_pkg.all;

entity imem is
    generic (
        ADDR_BITS : natural := 10;          -- words: 2**10 = 1024 (4 KiB), as in the slides
        INIT_FILE : string  := "imem.hex"
    );
    port (
        clk   : in  std_logic;
        addr  : in  word_t;                 -- byte address
        rdata : out word_t
    );
end entity imem;

architecture rtl of imem is
    constant DEPTH : natural := 2 ** ADDR_BITS;
    signal rom : word_array_t(0 to DEPTH - 1) := load_hex(INIT_FILE, DEPTH);
    attribute rom_style : string;
    attribute rom_style of rom : signal is "block";
begin
    process (clk)
    begin
        if rising_edge(clk) then
            rdata <= rom(to_integer(unsigned(addr(ADDR_BITS + 1 downto 2))));
        end if;
    end process;
end architecture rtl;
