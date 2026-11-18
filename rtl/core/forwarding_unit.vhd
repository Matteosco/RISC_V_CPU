-------------------------------------------------------------------------------
-- forwarding_unit.vhd -- Selects operand sources for the EX stage
--
--   FWD_NONE   : value read from the register file in ID
--   FWD_EX_MEM : result of the instruction one ahead (in MEM): its alu_result,
--                or next_pc for a jump
--   FWD_MEM_WB : rd_value of the instruction two ahead (in WB)
--
-- The EX/MEM path has priority because it holds the most recent value.
-- A load in MEM is never forwarded from EX/MEM: the hazard unit inserts one
-- bubble so the load reaches WB first (load-use stall).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use work.riscv_pkg.all;

entity forwarding_unit is
    port (
        ex_rs1          : in  reg_addr_t;
        ex_rs2          : in  reg_addr_t;
        mem_rd          : in  reg_addr_t;
        mem_rd_write_en : in  std_logic;
        wb_rd           : in  reg_addr_t;
        wb_rd_write_en  : in  std_logic;
        fwd_a           : out std_logic_vector(1 downto 0);
        fwd_b           : out std_logic_vector(1 downto 0)
    );
end entity forwarding_unit;

architecture rtl of forwarding_unit is
    constant FWD_NONE   : std_logic_vector(1 downto 0) := "00";
    constant FWD_EX_MEM : std_logic_vector(1 downto 0) := "10";
    constant FWD_MEM_WB : std_logic_vector(1 downto 0) := "01";

    function sel(rs : reg_addr_t; m_rd : reg_addr_t; m_we : std_logic;
                 w_rd : reg_addr_t; w_we : std_logic)
        return std_logic_vector is
    begin
        if rs = "00000" then
            return FWD_NONE;
        elsif m_we = '1' and m_rd = rs then
            return FWD_EX_MEM;
        elsif w_we = '1' and w_rd = rs then
            return FWD_MEM_WB;
        else
            return FWD_NONE;
        end if;
    end function;
begin
    fwd_a <= sel(ex_rs1, mem_rd, mem_rd_write_en, wb_rd, wb_rd_write_en);
    fwd_b <= sel(ex_rs2, mem_rd, mem_rd_write_en, wb_rd, wb_rd_write_en);
end architecture rtl;
