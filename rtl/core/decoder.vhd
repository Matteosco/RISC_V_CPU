-------------------------------------------------------------------------------
-- decoder.vhd -- Decode block of the slides: instruction -> control word (ID)
--
-- Outputs (fields of ctrl_t, slide names):
--   op_class    OSLBJ one-hot: Op, Store, Load, Branch, Jump
--   alu_opcode  ALU operation
--   a_sel       ALU input a: rs1_value, curr_pc (auipc, branches, jal) or 0 (lui)
--   b_sel       ALU input b: rs2_value or immediate
--   cond_opcode comparator operation (= funct3 of the branch)
--   imm_type    which immediate the sign extension builds
--   rd_write_en the instruction writes rd (classes O, L, J)
-- Branches and jumps use the ALU for the target: curr_pc + immediate
-- (rs1_value + immediate for jalr).
--
-- SYSTEM instructions: the Zicsr instructions (csrrw/s/c and the immediate
-- forms, class O) and MRET are decoded; ECALL, EBREAK, WFI and FENCE have
-- no effect (only interrupts are supported, no synchronous exceptions).
-- Unknown encodings set ctrl.illegal and have no effect either.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use work.riscv_pkg.all;

entity decoder is
    port (
        instr : in  word_t;
        ctrl  : out ctrl_t
    );
end entity decoder;

architecture rtl of decoder is
begin
    process (all)
        variable c      : ctrl_t;
        variable opcode : opcode_t;
        variable f3     : std_logic_vector(2 downto 0);
        variable f7     : std_logic_vector(6 downto 0);
    begin
        opcode := instr(6 downto 0);
        f3     := instr(14 downto 12);
        f7     := instr(31 downto 25);
        c      := CTRL_BUBBLE;
        c.funct3      := f3;
        c.cond_opcode := f3;

        case opcode is
            when OPC_LUI =>                     -- rd = 0 + imm
                c.op_class(OC_O) := '1';
                c.a_sel      := A_ZERO;
                c.b_sel      := B_IMM;
                c.alu_opcode := ALU_ADD;
                c.imm_type   := IMM_U;

            when OPC_AUIPC =>                   -- rd = curr_pc + imm
                c.op_class(OC_O) := '1';
                c.a_sel      := A_PC;
                c.b_sel      := B_IMM;
                c.alu_opcode := ALU_ADD;
                c.imm_type   := IMM_U;

            when OPC_JAL =>                     -- target = curr_pc + imm, rd = next_pc
                c.op_class(OC_J) := '1';
                c.a_sel      := A_PC;
                c.b_sel      := B_IMM;
                c.alu_opcode := ALU_ADD;
                c.imm_type   := IMM_J;

            when OPC_JALR =>                    -- target = rs1_value + imm, rd = next_pc
                c.op_class(OC_J) := '1';
                c.a_sel      := A_RS1;
                c.b_sel      := B_IMM;
                c.alu_opcode := ALU_ADD;
                c.imm_type   := IMM_I;
                c.uses_rs1   := '1';
                if f3 /= "000" then c.illegal := '1'; end if;

            when OPC_BRANCH =>                  -- target = curr_pc + imm, comparator decides
                c.op_class(OC_B) := '1';
                c.a_sel      := A_PC;
                c.b_sel      := B_IMM;
                c.alu_opcode := ALU_ADD;
                c.imm_type   := IMM_B;
                c.uses_rs1   := '1';
                c.uses_rs2   := '1';
                case f3 is
                    when "000" | "001" | "100" | "101" | "110" | "111" => null;
                    when others => c.illegal := '1';
                end case;

            when OPC_LOAD =>                    -- address = rs1_value + imm
                c.op_class(OC_L) := '1';
                c.a_sel      := A_RS1;
                c.b_sel      := B_IMM;
                c.alu_opcode := ALU_ADD;
                c.imm_type   := IMM_I;
                c.uses_rs1   := '1';
                case f3 is
                    when F3_B | F3_H | F3_W | F3_BU | F3_HU => null;
                    when others => c.illegal := '1';
                end case;

            when OPC_STORE =>                   -- address = rs1_value + imm
                c.op_class(OC_S) := '1';
                c.a_sel      := A_RS1;
                c.b_sel      := B_IMM;
                c.alu_opcode := ALU_ADD;
                c.imm_type   := IMM_S;
                c.uses_rs1   := '1';
                c.uses_rs2   := '1';
                case f3 is
                    when F3_B | F3_H | F3_W => null;
                    when others => c.illegal := '1';
                end case;

            when OPC_OPIMM =>                   -- rd = rs1_value op imm
                c.op_class(OC_O) := '1';
                c.a_sel      := A_RS1;
                c.b_sel      := B_IMM;
                c.imm_type   := IMM_I;
                c.uses_rs1   := '1';
                case f3 is
                    when "000" => c.alu_opcode := ALU_ADD;
                    when "010" => c.alu_opcode := ALU_SLT;
                    when "011" => c.alu_opcode := ALU_SLTU;
                    when "100" => c.alu_opcode := ALU_XOR;
                    when "110" => c.alu_opcode := ALU_OR;
                    when "111" => c.alu_opcode := ALU_AND;
                    when "001" =>
                        c.alu_opcode := ALU_SLL;
                        if f7 /= "0000000" then c.illegal := '1'; end if;
                    when "101" =>
                        if f7 = "0000000" then
                            c.alu_opcode := ALU_SRL;
                        elsif f7 = "0100000" then
                            c.alu_opcode := ALU_SRA;
                        else
                            c.illegal := '1';
                        end if;
                    when others => c.illegal := '1';
                end case;

            when OPC_OP =>                      -- rd = rs1_value op rs2_value
                c.op_class(OC_O) := '1';
                c.a_sel      := A_RS1;
                c.b_sel      := B_RS2;
                c.imm_type   := IMM_NONE;
                c.uses_rs1   := '1';
                c.uses_rs2   := '1';
                if f7 = "0000000" then
                    case f3 is
                        when "000"  => c.alu_opcode := ALU_ADD;
                        when "001"  => c.alu_opcode := ALU_SLL;
                        when "010"  => c.alu_opcode := ALU_SLT;
                        when "011"  => c.alu_opcode := ALU_SLTU;
                        when "100"  => c.alu_opcode := ALU_XOR;
                        when "101"  => c.alu_opcode := ALU_SRL;
                        when "110"  => c.alu_opcode := ALU_OR;
                        when "111"  => c.alu_opcode := ALU_AND;
                        when others => c.illegal := '1';
                    end case;
                elsif f7 = "0100000" and f3 = "000" then
                    c.alu_opcode := ALU_SUB;
                elsif f7 = "0100000" and f3 = "101" then
                    c.alu_opcode := ALU_SRA;
                else
                    c.illegal := '1';
                end if;

            when OPC_SYSTEM =>
                case f3 is
                    when "000" =>                       -- ECALL/EBREAK/WFI/MRET
                        if instr = x"30200073" then
                            c.mret := '1';              -- return from interrupt
                        end if;                         -- others: no effect
                    when "001" | "010" | "011" | "101" | "110" | "111" =>
                        -- csrrw/csrrs/csrrc (rs1) and csrrwi/csrrsi/csrrci (uimm)
                        c.op_class(OC_O) := '1';        -- rd = old CSR value
                        c.imm_type  := IMM_I;           -- imm[11:0] = CSR number
                        case f3(1 downto 0) is
                            when "01"   => c.csr_op := CSR_RW;
                            when "10"   => c.csr_op := CSR_RS;
                            when others => c.csr_op := CSR_RC;
                        end case;
                        c.csr_imm  := f3(2);
                        c.uses_rs1 := not f3(2);        -- the immediate forms read no register
                    when others =>
                        c.illegal := '1';
                end case;

            when OPC_FENCE =>
                null;  -- no effect in this core

            when others =>
                c.illegal := '1';
        end case;

        -- An illegal instruction must not change architectural state
        if c.illegal = '1' then
            c.op_class := OC_NONE;
            c.csr_op   := CSR_NONE;
            c.mret     := '0';
        end if;

        -- rd is written by ALU operations, loads and jumps (slides)
        c.rd_write_en := c.op_class(OC_O) or c.op_class(OC_L) or c.op_class(OC_J);

        ctrl <= c;
    end process;
end architecture rtl;
