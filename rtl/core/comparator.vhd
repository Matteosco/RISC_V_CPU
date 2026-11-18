-------------------------------------------------------------------------------
-- comparator.vhd -- Branch condition (EX), as the COMP block of the slides
--
-- Compares the two register values according to cond_opcode (= funct3 of the
-- branch) and says whether the branch is taken. The branch target is not
-- computed here: the ALU computes it (curr_pc + immediate).
--
--   cond_opcode  instr   branch_cond
--   000          beq     rs1 =  rs2
--   001          bne     rs1 /= rs2
--   100          blt     rs1 <  rs2  (signed)
--   101          bge     rs1 >= rs2  (signed)
--   110          bltu    rs1 <  rs2  (unsigned)
--   111          bgeu    rs1 >= rs2  (unsigned)
--   others               false
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.riscv_pkg.all;

entity comparator is
    port (
        cond_opcode : in  std_logic_vector(2 downto 0);
        rs1_value   : in  word_t;    -- forwarded operands
        rs2_value   : in  word_t;
        branch_cond : out std_logic
    );
end entity comparator;

architecture rtl of comparator is
    signal eq, lt, ltu : boolean;
begin
    eq  <= rs1_value = rs2_value;
    lt  <= signed(rs1_value) < signed(rs2_value);
    ltu <= unsigned(rs1_value) < unsigned(rs2_value);

    process (all)
    begin
        case cond_opcode is
            when "000"  => branch_cond <= '1' when eq      else '0';
            when "001"  => branch_cond <= '1' when not eq  else '0';
            when "100"  => branch_cond <= '1' when lt      else '0';
            when "101"  => branch_cond <= '1' when not lt  else '0';
            when "110"  => branch_cond <= '1' when ltu     else '0';
            when "111"  => branch_cond <= '1' when not ltu else '0';
            when others => branch_cond <= '0';
        end case;
    end process;
end architecture rtl;
