-------------------------------------------------------------------------------
-- cpu_core.vhd -- 5-stage pipelined RV32I core
--
--   IF -> ID -> EX -> MEM -> WB
--
-- The blocks and signals follow the course slides (non-pipelined CPU), cut
-- into five stages by the pipeline registers if_id, id_ex, ex_mem, mem_wb:
--   IF  : pc, pc_in, pc_load, next_pc (= pc + 4), instruction memory
--   ID  : decoder (op_class OSLBJ, alu_opcode, a_sel, b_sel, cond_opcode),
--         register file (rs1_value, rs2_value), immediate
--   EX  : ALU (alu_pre_result: data memory address, branch/jump target),
--         comparator (branch_cond -> Cond)
--   MEM : data memory (mem_we, mem_out -> LMD), PC = ALUOutput if Cond (pc_out)
--   WB  : rd_value = ALUOutput / LMD / NPC, register file write (rd_write_en)
-- The pipeline register fields use the names of the lecture (Hennessy &
-- Patterson): IR, NPC, A, B, Imm, ALUOutput, Cond, LMD.
--
-- Hazard handling (entirely in hardware):
--   * Data hazards : forwarding EX/MEM->EX and MEM/WB->EX, write-through
--                    register file for WB->ID, 1-cycle stall on load-use.
--   * Control      : IF asks the branch predictor (BTB + 2-bit counters,
--                    branch_predictor.vhd) where to fetch next. Branches and
--                    jumps resolve in MEM, as in the lecture (PC = ALUOutput
--                    if Cond); only when the prediction was wrong are the
--                    three younger instructions (IF/ID, ID/EX, EX) flushed
--                    (3-cycle penalty).
--                    With BRANCH_PRED = false: always predict not-taken.
--
-- Interrupts (csr_unit.vhd): when the interrupt line is active and enabled
-- (mstatus.MIE and mie.MEIE), it is taken on the instruction in EX: that
-- instruction is cancelled (it does not write registers, memory, IO or
-- CSRs), its PC goes to mepc, the instructions in IF and ID are flushed and
-- fetch continues at mtvec. Everything older (MEM, WB) completes, so the
-- interrupt is precise. MRET in EX returns to mepc (IF and ID flushed).
-- When the branch in MEM was mispredicted, the instruction in EX is on the
-- wrong path: it is cancelled too (no store, no IO read, no CSR write) and
-- an interrupt or MRET waits for a right-path instruction.
--
-- Memory interfaces (both synchronous, BRAM friendly):
--   * Instruction port: imem_addr is the PC of the next fetch (pc_in when the
--     PC loads, pc otherwise); the memory registers it, so imem_rdata is the
--     instruction at pc during IF.
--   * Data port: address (alu_pre_result), data and strobes are driven from
--     EX; the memory samples them at the EX->MEM clock edge (stores commit
--     there) and returns mem_out during MEM -- as in the slides, where the
--     ALU "pre result" addresses the data memory one cycle early.
--
-- Clock enable (en): when '0' the whole pipeline is frozen -- PC, all four
-- pipeline registers and every write (register file, memory, IO) hold.
-- Used by the single-step debug mode in soc.vhd; tied to '1' otherwise.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.riscv_pkg.all;

entity cpu_core is
    generic (
        RESET_ADDR  : word_t  := RESET_VECTOR;
        BRANCH_PRED : boolean := true;    -- dynamic branch prediction
        BTB_BITS    : natural := 4        -- 2**BTB_BITS predictor entries
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;   -- synchronous, active high
        en         : in  std_logic := '1';   -- clock enable (single-step)
        ext_irq    : in  std_logic := '0';   -- interrupt controller line (MEIP)
        -- instruction memory
        imem_addr  : out word_t;
        imem_rdata : in  word_t;
        -- data bus
        dbus_addr  : out word_t;
        dbus_wdata : out word_t;
        dbus_be    : out std_logic_vector(3 downto 0);
        dbus_we    : out std_logic;
        dbus_re    : out std_logic;
        dbus_rdata : in  word_t;
        -- performance / debug
        retire     : out std_logic;   -- one instruction completed (WB)
        stall_evt  : out std_logic;   -- load-use bubble inserted
        flush_evt  : out std_logic;   -- mispredicted branch / jump (3 bubbles)
        branch_evt : out std_logic;   -- a branch or jump resolved in MEM
        dbg_pc_wb  : out word_t;      -- PC of the instruction in WB
        illegal    : out std_logic;   -- illegal instruction reached EX
        -- pipeline view for the debug display
        dbg_pc_if  : out word_t;      -- PC being fetched
        dbg_pc_id  : out word_t;      -- PC in IF/ID
        dbg_pc_ex  : out word_t;      -- PC in ID/EX
        dbg_pc_mem : out word_t;      -- PC in EX/MEM
        dbg_valid  : out std_logic_vector(3 downto 0);  -- ID, EX, MEM, WB hold a real instruction
        dbg_stall_now : out std_logic;  -- load-use stall in this cycle
        dbg_flush_now : out std_logic;  -- IF/ID flushed at the next edge (misprediction, interrupt, mret)
        dbg_irq_now   : out std_logic;  -- an interrupt is taken in this cycle
        dbg_csr       : out std_logic_vector(2 downto 0);  -- MEIE, MPIE, MIE
        -- register file debug read (simulation register dump)
        dbg_wb_we     : out std_logic;  -- WB writes a register (rd /= x0)
        dbg_wb_rd     : out reg_addr_t; -- ... which one
        dbg_wb_data   : out word_t;     -- ... with this value
        dbg_reg_addr  : in  reg_addr_t := "00000";
        dbg_reg_data  : out word_t
    );
end entity cpu_core;

architecture rtl of cpu_core is

    ---------------------------------------------------------------------------
    -- Pipeline registers. Field names follow the lecture (Hennessy &
    -- Patterson): IR, NPC, A, B, Imm, ALUOutput, Cond, LMD.
    ---------------------------------------------------------------------------
    type if_id_t is record
        valid       : std_logic;
        curr_pc     : word_t;         -- PC of this instruction
        npc         : word_t;         -- NPC = PC + 4
        ir          : word_t;         -- IR  = Mem[PC]
        pred_taken  : std_logic;      -- prediction made in IF for this instruction
        pred_target : word_t;
    end record;

    type id_ex_t is record
        valid       : std_logic;
        curr_pc     : word_t;
        npc         : word_t;
        rs1         : reg_addr_t;
        rs2         : reg_addr_t;
        rd          : reg_addr_t;
        a           : word_t;         -- A   = Regs[rs1]
        b           : word_t;         -- B   = Regs[rs2]
        imm         : word_t;         -- Imm = sign-extended immediate
        ctrl        : ctrl_t;
        pred_taken  : std_logic;
        pred_target : word_t;
    end record;

    type ex_mem_t is record
        valid       : std_logic;
        curr_pc     : word_t;
        npc         : word_t;
        rd          : reg_addr_t;
        alu_output  : word_t;         -- ALUOutput (CSR instr: old CSR value)
        cond        : std_logic;      -- Cond: the branch/jump is taken
        ctrl        : ctrl_t;
        pred_taken  : std_logic;
        pred_target : word_t;
    end record;

    type mem_wb_t is record
        valid       : std_logic;
        curr_pc     : word_t;
        npc         : word_t;
        rd          : reg_addr_t;
        alu_output  : word_t;         -- ALUOutput
        lmd         : word_t;         -- LMD = Mem[ALUOutput] (aligned, extended)
        ctrl        : ctrl_t;
    end record;

    constant IF_ID_BUBBLE : if_id_t := (valid => '0', curr_pc => ZERO_WORD,
        npc => ZERO_WORD, ir => ZERO_WORD, pred_taken => '0', pred_target => ZERO_WORD);
    constant ID_EX_BUBBLE : id_ex_t := (
        valid => '0', curr_pc => ZERO_WORD, npc => ZERO_WORD,
        rs1 => "00000", rs2 => "00000", rd => "00000",
        a => ZERO_WORD, b => ZERO_WORD, imm => ZERO_WORD,
        ctrl => CTRL_BUBBLE, pred_taken => '0', pred_target => ZERO_WORD);
    constant EX_MEM_BUBBLE : ex_mem_t := (
        valid => '0', curr_pc => ZERO_WORD, npc => ZERO_WORD, rd => "00000",
        alu_output => ZERO_WORD, cond => '0', ctrl => CTRL_BUBBLE,
        pred_taken => '0', pred_target => ZERO_WORD);
    constant MEM_WB_BUBBLE : mem_wb_t := (
        valid => '0', curr_pc => ZERO_WORD, npc => ZERO_WORD, rd => "00000",
        alu_output => ZERO_WORD, lmd => ZERO_WORD, ctrl => CTRL_BUBBLE);

    signal if_id  : if_id_t  := IF_ID_BUBBLE;
    signal id_ex  : id_ex_t  := ID_EX_BUBBLE;
    signal ex_mem : ex_mem_t := EX_MEM_BUBBLE;
    signal mem_wb : mem_wb_t := MEM_WB_BUBBLE;

    -- IF
    signal pc        : word_t := RESET_ADDR;   -- program counter
    signal pc_in     : word_t;                 -- value loaded into pc
    signal pc_load   : std_logic;              -- pc takes pc_in at the clock edge
    signal next_pc   : word_t;                 -- pc + 4 (becomes NPC)
    signal bp_taken  : std_logic;              -- predictor: fetch the target next
    signal bp_target : word_t;

    -- ID
    signal id_ctrl_dec  : ctrl_t;
    signal id_ctrl      : ctrl_t;
    signal id_rs1       : reg_addr_t;
    signal id_rs2       : reg_addr_t;
    signal id_rd        : reg_addr_t;
    signal id_rs1_value : word_t;
    signal id_rs2_value : word_t;
    signal immediate    : word_t;

    -- EX
    signal fwd_a, fwd_b   : std_logic_vector(1 downto 0);
    signal rs1_value      : word_t;     -- A and B after forwarding
    signal rs2_value      : word_t;
    signal alu_a          : word_t;
    signal alu_b          : word_t;
    signal alu_pre_result : word_t;     -- ALU output: data address, branch target
    signal ex_result      : word_t;     -- alu_pre_result, or the CSR value
    signal branch_cond    : std_logic;  -- comparator: branch condition true
    signal ex_cond        : std_logic;  -- J, or B with branch_cond (becomes Cond)
    signal ex_cancel      : std_logic;  -- the instruction in EX does not complete
    signal mem_we         : std_logic;  -- store
    signal mem_re         : std_logic;  -- load (IO registers with side effects)

    -- MEM
    signal mem_out       : word_t;     -- Mem[ALUOutput], aligned and extended
    signal mem_target    : word_t;     -- ALUOutput with bit 0 cleared (jalr)
    signal mem_is_branch : std_logic;  -- B or J in MEM (predictor update)
    signal pc_out        : word_t;     -- where the program really goes
    signal mispredict    : std_logic;  -- PC != predicted: fetch pc_out
    signal ex_mem_fwd    : word_t;     -- value forwarded from EX/MEM

    -- CSRs / interrupts
    signal csr_rdata     : word_t;
    signal csr_mtvec     : word_t;
    signal csr_mepc      : word_t;
    signal irq_req       : std_logic;  -- interrupt pending and enabled
    signal irq_take      : std_logic;  -- take it now (cancels the instruction in EX)
    signal mret_take     : std_logic;  -- MRET in EX
    signal ctl_flush     : std_logic;  -- any change of the program flow
    signal csr_valid     : std_logic;

    -- WB
    signal rd_value    : word_t;       -- Rd = ALUOutput / LMD / NPC
    signal rd_write_en : std_logic;

    -- hazard control
    signal stall_if, stall_id, flush_id, flush_ex, flush_mem : std_logic;

begin

    ---------------------------------------------------------------------------
    -- IF : IR = Mem[PC], NPC = PC + 4
    ---------------------------------------------------------------------------
    next_pc <= std_logic_vector(unsigned(pc) + 4);

    -- pc_in: where to fetch next, in order of priority. A misprediction in
    -- MEM comes first: the instruction in EX is then on the wrong path, so
    -- it can take no interrupt and no MRET (irq_take = mret_take = 0).
    pc_in <= pc_out    when mispredict = '1' else   -- PC = ALUOutput if Cond, else NPC
             csr_mtvec when irq_take   = '1' else   -- interrupt: go to the handler
             csr_mepc  when mret_take  = '1' else   -- return from the handler
             bp_target when bp_taken   = '1' else   -- predicted taken
             next_pc;

    -- pc_load: the PC holds when the pipeline is frozen (en = 0) or during a
    -- load-use stall; a change of flow always loads it
    pc_load <= en and (ctl_flush or not stall_if);

    -- the instruction memory registers its address: give it the PC of the
    -- next fetch (when the PC holds, the same instruction is read again)
    imem_addr <= RESET_ADDR when rst = '1' else
                 pc_in      when pc_load = '1' else
                 pc;

    u_bp : entity work.branch_predictor
        generic map (ENABLE => BRANCH_PRED, IDX_BITS => BTB_BITS)
        port map (
            clk         => clk,
            rst         => rst,
            en          => en,
            lookup_pc   => pc,
            pred_taken  => bp_taken,
            pred_target => bp_target,
            upd_valid   => mem_is_branch,            -- learns when the branch resolves (MEM)
            upd_pc      => ex_mem.curr_pc,
            upd_taken   => ex_mem.cond,
            upd_target  => mem_target,
            upd_jump    => ex_mem.ctrl.op_class(OC_J));

    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                pc <= RESET_ADDR;
            elsif pc_load = '1' then
                pc <= pc_in;
            end if;

            -- IF/ID register
            if rst = '1' then
                if_id <= IF_ID_BUBBLE;
            elsif en = '0' then
                null;                        -- frozen
            elsif flush_id = '1' then
                if_id <= IF_ID_BUBBLE;
            elsif stall_id = '0' then
                if_id.valid       <= '1';
                if_id.curr_pc     <= pc;
                if_id.npc         <= next_pc;
                if_id.ir          <= imem_rdata;
                if_id.pred_taken  <= bp_taken;
                if_id.pred_target <= bp_target;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- ID : A = Regs[rs1], B = Regs[rs2], Imm = sign-extend; decode, hazards
    ---------------------------------------------------------------------------
    id_rs1 <= if_id.ir(19 downto 15);
    id_rs2 <= if_id.ir(24 downto 20);
    id_rd  <= if_id.ir(11 downto 7);

    u_decoder : entity work.decoder
        port map (instr => if_id.ir, ctrl => id_ctrl_dec);

    id_ctrl <= id_ctrl_dec when if_id.valid = '1' else CTRL_BUBBLE;

    u_imm : entity work.imm_gen
        port map (instr => if_id.ir, imm_type => id_ctrl.imm_type, imm => immediate);

    u_regfile : entity work.regfile
        port map (
            clk      => clk,
            rs1_addr => id_rs1,
            rs2_addr => id_rs2,
            rs1_data => id_rs1_value,
            rs2_data => id_rs2_value,
            we       => rd_write_en,
            rd_addr  => mem_wb.rd,
            rd_data  => rd_value,
            dbg_addr => dbg_reg_addr,
            dbg_data => dbg_reg_data);

    u_hazard : entity work.hazard_unit
        port map (
            id_rs1      => id_rs1,
            id_rs2      => id_rs2,
            id_uses_rs1 => id_ctrl.uses_rs1,
            id_uses_rs2 => id_ctrl.uses_rs2,
            ex_rd       => id_ex.rd,
            ex_is_load  => id_ex.ctrl.op_class(OC_L),
            mispredict  => mispredict,
            irq_take    => irq_take,
            mret_take   => mret_take,
            stall_if    => stall_if,
            stall_id    => stall_id,
            flush_id    => flush_id,
            flush_ex    => flush_ex,
            flush_mem   => flush_mem);

    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                id_ex <= ID_EX_BUBBLE;
            elsif en = '0' then
                null;                        -- frozen
            elsif flush_ex = '1' then
                id_ex <= ID_EX_BUBBLE;
            else
                id_ex.valid   <= if_id.valid;
                id_ex.curr_pc <= if_id.curr_pc;
                id_ex.npc     <= if_id.npc;
                id_ex.rs1     <= id_rs1;
                id_ex.rs2     <= id_rs2;
                -- rd = x0 when the instruction does not write a register,
                -- so forwarding/hazard logic never matches on it
                id_ex.rd      <= id_rd when id_ctrl.rd_write_en = '1' else "00000";
                id_ex.a       <= id_rs1_value;
                id_ex.b       <= id_rs2_value;
                id_ex.imm     <= immediate;
                id_ex.ctrl    <= id_ctrl;
                id_ex.pred_taken  <= if_id.pred_taken;
                id_ex.pred_target <= if_id.pred_target;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- EX : ALUOutput = A op B / A op Imm / A + Imm / PC + Imm, Cond
    ---------------------------------------------------------------------------
    u_fwd : entity work.forwarding_unit
        port map (
            ex_rs1          => id_ex.rs1,
            ex_rs2          => id_ex.rs2,
            mem_rd          => ex_mem.rd,
            mem_rd_write_en => ex_mem.ctrl.rd_write_en,
            wb_rd           => mem_wb.rd,
            wb_rd_write_en  => mem_wb.ctrl.rd_write_en,
            fwd_a           => fwd_a,
            fwd_b           => fwd_b);

    with fwd_a select rs1_value <=
        ex_mem_fwd when "10",
        rd_value   when "01",
        id_ex.a    when others;

    with fwd_b select rs2_value <=
        ex_mem_fwd when "10",
        rd_value   when "01",
        id_ex.b    when others;

    -- ALU input muxes (a_sel, b_sel)
    with id_ex.ctrl.a_sel select alu_a <=
        rs1_value     when A_RS1,
        id_ex.curr_pc when A_PC,
        ZERO_WORD     when A_ZERO;

    alu_b <= rs2_value when id_ex.ctrl.b_sel = B_RS2 else id_ex.imm;

    u_alu : entity work.alu
        port map (alu_opcode => id_ex.ctrl.alu_opcode, a => alu_a, b => alu_b,
                  result => alu_pre_result);

    u_comp : entity work.comparator
        port map (
            cond_opcode => id_ex.ctrl.cond_opcode,
            rs1_value   => rs1_value,
            rs2_value   => rs2_value,
            branch_cond => branch_cond);

    -- CSR instructions write the old CSR value into rd
    ex_result <= csr_rdata when id_ex.ctrl.csr_op /= CSR_NONE else alu_pre_result;

    -- Cond: jumps are always taken, branches when the comparator says so
    ex_cond <= id_ex.ctrl.op_class(OC_J) or
               (id_ex.ctrl.op_class(OC_B) and branch_cond);

    -- the instruction in EX does not complete when the branch in MEM was
    -- mispredicted (EX is on the wrong path) or when an interrupt takes it
    ex_cancel <= mispredict or irq_take;

    ---------------------------------------------------------------------------
    -- CSRs and interrupts (on the instruction in EX)
    ---------------------------------------------------------------------------
    -- An interrupt needs a real instruction in EX (its PC becomes mepc) that
    -- is on the right path; otherwise it simply waits.
    irq_take  <= irq_req and id_ex.valid and not mispredict;
    mret_take <= id_ex.valid and id_ex.ctrl.mret and not irq_take and not mispredict;
    ctl_flush <= mispredict or irq_take or mret_take;
    csr_valid <= '1' when id_ex.valid = '1' and id_ex.ctrl.csr_op /= CSR_NONE and
                          mispredict = '0' else '0';

    u_csr : entity work.csr_unit
        port map (
            clk       => clk,
            rst       => rst,
            en        => en,
            csr_valid => csr_valid,
            csr_op    => id_ex.ctrl.csr_op,
            csr_imm   => id_ex.ctrl.csr_imm,
            csr_addr  => id_ex.imm(11 downto 0),
            rs1_field => id_ex.rs1,
            rs1_val   => rs1_value,
            rdata     => csr_rdata,
            trap      => irq_take,
            trap_pc   => id_ex.curr_pc,
            mret      => mret_take,
            ext_irq   => ext_irq,
            irq_req   => irq_req,
            mtvec     => csr_mtvec,
            mepc      => csr_mepc,
            dbg_bits  => dbg_csr);

    -- Data memory request. The memory is a synchronous BRAM: it takes the
    -- address (ALUOutput, still unlatched = alu_pre_result) and B at the
    -- EX->MEM clock edge and answers during MEM. A cancelled load/store must
    -- not touch memory or IO.
    mem_we    <= id_ex.ctrl.op_class(OC_S) and en and not ex_cancel;
    mem_re    <= id_ex.ctrl.op_class(OC_L) and en and not ex_cancel;
    dbus_addr <= alu_pre_result;
    dbus_we   <= mem_we;
    dbus_re   <= mem_re;

    process (all)
        variable off : std_logic_vector(1 downto 0);
    begin
        off := alu_pre_result(1 downto 0);
        case id_ex.ctrl.funct3(1 downto 0) is
            when "00" =>  -- byte
                dbus_wdata <= rs2_value(7 downto 0) & rs2_value(7 downto 0)
                            & rs2_value(7 downto 0) & rs2_value(7 downto 0);
                case off is
                    when "00"   => dbus_be <= "0001";
                    when "01"   => dbus_be <= "0010";
                    when "10"   => dbus_be <= "0100";
                    when others => dbus_be <= "1000";
                end case;
            when "01" =>  -- half
                dbus_wdata <= rs2_value(15 downto 0) & rs2_value(15 downto 0);
                dbus_be    <= "1100" when off(1) = '1' else "0011";
            when others =>  -- word
                dbus_wdata <= rs2_value;
                dbus_be    <= "1111";
        end case;
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ex_mem <= EX_MEM_BUBBLE;
            elsif en = '1' and flush_mem = '1' then
                ex_mem <= EX_MEM_BUBBLE;     -- wrong path or interrupted: cancelled
            elsif en = '1' then
                ex_mem.valid       <= id_ex.valid;
                ex_mem.curr_pc     <= id_ex.curr_pc;
                ex_mem.npc         <= id_ex.npc;
                ex_mem.rd          <= id_ex.rd;
                ex_mem.alu_output  <= ex_result;
                ex_mem.cond        <= ex_cond;
                ex_mem.ctrl        <= id_ex.ctrl;
                ex_mem.pred_taken  <= id_ex.pred_taken;
                ex_mem.pred_target <= id_ex.pred_target;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- MEM : LMD = Mem[ALUOutput]; if (Cond) PC = ALUOutput else NPC
    ---------------------------------------------------------------------------
    process (all)
        variable shifted : word_t;
    begin
        shifted := std_logic_vector(shift_right(unsigned(dbus_rdata),
                                    8 * to_integer(unsigned(ex_mem.alu_output(1 downto 0)))));
        case ex_mem.ctrl.funct3 is
            when F3_B   => mem_out <= std_logic_vector(resize(signed(shifted(7 downto 0)), 32));
            when F3_BU  => mem_out <= std_logic_vector(resize(unsigned(shifted(7 downto 0)), 32));
            when F3_H   => mem_out <= std_logic_vector(resize(signed(shifted(15 downto 0)), 32));
            when F3_HU  => mem_out <= std_logic_vector(resize(unsigned(shifted(15 downto 0)), 32));
            when others => mem_out <= dbus_rdata;
        end case;
    end process;

    -- next PC (lecture: PC = ALUOutput if Cond; slides: pc_out). Bit 0 of
    -- the target is cleared (needed by jalr).
    mem_target    <= ex_mem.alu_output(31 downto 1) & '0';
    pc_out        <= mem_target when ex_mem.cond = '1' else ex_mem.npc;
    mem_is_branch <= ex_mem.valid and en and
                     (ex_mem.ctrl.op_class(OC_B) or ex_mem.ctrl.op_class(OC_J));

    -- misprediction: the predicted direction was wrong, or the prediction was
    -- "taken" but to a different target (e.g. a JALR returning elsewhere)
    mispredict <= ex_mem.valid when (ex_mem.cond /= ex_mem.pred_taken) or
                                    (ex_mem.cond = '1' and mem_target /= ex_mem.pred_target)
                  else '0';

    -- value forwarded from EX/MEM: a load is never forwarded from here (its
    -- data is not there yet: load-use stall), so only J (NPC) and O matter
    ex_mem_fwd <= ex_mem.npc when ex_mem.ctrl.op_class(OC_J) = '1' else
                  ex_mem.alu_output;

    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                mem_wb <= MEM_WB_BUBBLE;
            elsif en = '1' then
                mem_wb.valid      <= ex_mem.valid;
                mem_wb.curr_pc    <= ex_mem.curr_pc;
                mem_wb.npc        <= ex_mem.npc;
                mem_wb.rd         <= ex_mem.rd;
                mem_wb.alu_output <= ex_mem.alu_output;
                mem_wb.lmd        <= mem_out;
                mem_wb.ctrl       <= ex_mem.ctrl;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- WB : Rd = ALUOutput (O), LMD (L) or NPC (J)
    ---------------------------------------------------------------------------
    rd_value <= mem_wb.lmd when mem_wb.ctrl.op_class(OC_L) = '1' else
                mem_wb.npc when mem_wb.ctrl.op_class(OC_J) = '1' else
                mem_wb.alu_output;

    rd_write_en <= mem_wb.ctrl.rd_write_en and en;

    retire     <= mem_wb.valid and en;
    dbg_wb_we   <= rd_write_en when mem_wb.rd /= "00000" else '0';
    dbg_wb_rd   <= mem_wb.rd;
    dbg_wb_data <= rd_value;
    dbg_pc_wb  <= mem_wb.curr_pc;
    stall_evt  <= stall_id and en;
    flush_evt  <= mispredict and en;
    branch_evt <= mem_is_branch;
    illegal    <= id_ex.valid and id_ex.ctrl.illegal and en and not ex_cancel;

    dbg_pc_if     <= pc;
    dbg_pc_id     <= if_id.curr_pc;
    dbg_pc_ex     <= id_ex.curr_pc;
    dbg_pc_mem    <= ex_mem.curr_pc;
    dbg_valid     <= if_id.valid & id_ex.valid & ex_mem.valid & mem_wb.valid;
    dbg_stall_now <= stall_id;
    dbg_flush_now <= ctl_flush;
    dbg_irq_now   <= irq_take;

end architecture rtl;
