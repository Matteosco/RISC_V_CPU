-------------------------------------------------------------------------------
-- regfile.vhd -- 32 x 32-bit register file, 2 async read ports, 1 write port
--
-- x0 is hard-wired to zero. Reads are write-through ("write-before-read"):
-- if WB writes a register in the same cycle ID reads it, the new value is
-- returned. This covers the producer-in-WB / consumer-in-ID hazard so the
-- forwarding unit only needs EX/MEM and MEM/WB paths.
-- Maps to distributed (LUT) RAM on Xilinx 7-series.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.riscv_pkg.all;

entity regfile is
    port (
        clk      : in  std_logic;
        -- read ports
        rs1_addr : in  reg_addr_t;
        rs2_addr : in  reg_addr_t;
        rs1_data : out word_t;
        rs2_data : out word_t;
        -- write port
        we       : in  std_logic;
        rd_addr  : in  reg_addr_t;
        rd_data  : in  word_t
    );
end entity regfile;

architecture rtl of regfile is
    signal regs : word_array_t(0 to 31) := (others => ZERO_WORD);
begin
    process (clk)
    begin
        if rising_edge(clk) then
            if we = '1' and rd_addr /= "00000" then
                regs(to_integer(unsigned(rd_addr))) <= rd_data;
            end if;
        end if;
    end process;


    process (all)
    begin
        if rs1_addr = "00000" then
            rs1_data <= ZERO_WORD;
        elsif we = '1' and rd_addr = rs1_addr then
            rs1_data <= rd_data;
        else
            rs1_data <= regs(to_integer(unsigned(rs1_addr)));
        end if;

        if rs2_addr = "00000" then
            rs2_data <= ZERO_WORD;
        elsif we = '1' and rd_addr = rs2_addr then
            rs2_data <= rd_data;
        else
            rs2_data <= regs(to_integer(unsigned(rs2_addr)));
        end if;
    end process;
end architecture rtl;
