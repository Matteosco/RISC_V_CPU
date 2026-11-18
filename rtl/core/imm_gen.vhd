-------------------------------------------------------------------------------
-- imm_gen.vhd -- Immediate generator for all RV32I instruction formats
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use work.riscv_pkg.all;

entity imm_gen is
    port (
        instr    : in  word_t;
        imm_type : in  imm_type_t;
        imm      : out word_t
    );
end entity imm_gen;

architecture rtl of imm_gen is
begin
    process (all)
        variable s : std_logic;
    begin
        s := instr(31);
        case imm_type is
            when IMM_I =>
                imm <= (31 downto 11 => s) & instr(30 downto 20);
            when IMM_S =>
                imm <= (31 downto 11 => s) & instr(30 downto 25) & instr(11 downto 7);
            when IMM_B =>
                imm <= (31 downto 12 => s) & instr(7) & instr(30 downto 25)
                       & instr(11 downto 8) & '0';
            when IMM_U =>
                imm <= instr(31 downto 12) & x"000";
            when IMM_J =>
                imm <= (31 downto 20 => s) & instr(19 downto 12) & instr(20)
                       & instr(30 downto 21) & '0';
            when IMM_NONE =>
                imm <= ZERO_WORD;
        end case;
    end process;
end architecture rtl;
