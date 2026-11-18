-------------------------------------------------------------------------------
-- csr_unit.vhd -- Machine-mode CSRs and interrupt entry / return (EX stage)
--
-- Implemented CSRs (everything else reads as 0 and ignores writes):
--   mstatus  0x300  bit3 MIE (global interrupt enable), bit7 MPIE (MIE before
--                   the trap); MPP (bits 12:11) always reads 11 = machine mode
--   misa     0x301  read-only, RV32I
--   mie      0x304  bit11 MEIE (machine external interrupt enable)
--   mtvec    0x305  trap handler address (direct mode, bits 1:0 = 0)
--   mscratch 0x340  free register for the handler
--   mepc     0x341  PC of the interrupted instruction (bits 1:0 = 0)
--   mcause   0x342  0x8000000B = machine external interrupt
--   mip      0x344  read-only, bit11 MEIP = the interrupt controller's line
--
-- The CSR instruction in EX reads the OLD value (it goes to rd through the
-- normal result path, so forwarding works) and writes the new one at the
-- EX->MEM clock edge, the same edge where stores commit. CSRRS/CSRRC (and
-- the immediate forms) with rs1 = x0 / uimm = 0 only read.
--
-- Priority at a clock edge: trap entry > MRET > CSR write.
--   trap : mepc <= trap_pc, mcause <= MEI, MPIE <= MIE, MIE <= 0
--   mret : MIE <= MPIE, MPIE <= 1
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.riscv_pkg.all;

entity csr_unit is
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        en        : in  std_logic;                    -- CPU clock enable
        -- CSR instruction in EX
        csr_valid : in  std_logic;                    -- valid CSR instruction in EX
        csr_op    : in  csr_op_t;
        csr_imm   : in  std_logic;                    -- source = zero-extended rs1 field
        csr_addr  : in  csr_addr_t;
        rs1_field : in  reg_addr_t;
        rs1_val   : in  word_t;                       -- forwarded rs1 value
        rdata     : out word_t;                       -- old CSR value -> rd
        -- trap entry / return
        trap      : in  std_logic;                    -- take the interrupt now
        trap_pc   : in  word_t;                       -- PC of the instruction in EX
        mret      : in  std_logic;                    -- valid MRET in EX
        ext_irq   : in  std_logic;                    -- interrupt controller line
        irq_req   : out std_logic;                    -- MIE and MEIE and MEIP
        mtvec     : out word_t;
        mepc      : out word_t;
        dbg_bits  : out std_logic_vector(2 downto 0)  -- debug: MEIE, MPIE, MIE
    );
end entity csr_unit;

architecture rtl of csr_unit is
    signal st_mie, st_mpie : std_logic := '0';       -- mstatus bits
    signal meie_r        : std_logic := '0';       -- mie.MEIE
    signal mtvec_r, mepc_r, mcause_r, mscratch_r : word_t := ZERO_WORD;

    signal cur_mstatus, cur_mie, cur_mip, old_val, src, new_val : word_t;
    signal do_write : std_logic;
begin
    cur_mstatus <= (MSTATUS_MIE => st_mie, MSTATUS_MPIE => st_mpie,
                    12 => '1', 11 => '1', others => '0');
    cur_mie     <= (MIE_MEIE => meie_r, others => '0');
    cur_mip     <= (MIP_MEIP => ext_irq, others => '0');

    -- read (old value of the addressed CSR)
    with csr_addr select old_val <=
        cur_mstatus when CSR_MSTATUS,
        MISA_RV32I  when CSR_MISA,
        cur_mie     when CSR_MIE,
        mtvec_r     when CSR_MTVEC,
        mscratch_r  when CSR_MSCRATCH,
        mepc_r      when CSR_MEPC,
        mcause_r    when CSR_MCAUSE,
        cur_mip     when CSR_MIP,
        ZERO_WORD   when others;
    rdata <= old_val;

    -- new value: write / set bits / clear bits
    src <= (31 downto 5 => '0') & rs1_field when csr_imm = '1' else rs1_val;
    with csr_op select new_val <=
        src                   when CSR_RW,
        old_val or src        when CSR_RS,
        old_val and not src   when CSR_RC,
        old_val               when others;
    -- set/clear with x0 (or uimm 0) is a pure read
    do_write <= '1' when csr_valid = '1' and
                         (csr_op = CSR_RW or
                          ((csr_op = CSR_RS or csr_op = CSR_RC) and rs1_field /= "00000"))
                else '0';

    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                st_mie     <= '0';
                st_mpie    <= '0';
                meie_r   <= '0';
                mtvec_r    <= ZERO_WORD;
                mepc_r     <= ZERO_WORD;
                mcause_r   <= ZERO_WORD;
                mscratch_r <= ZERO_WORD;
            elsif en = '1' then
                if trap = '1' then                      -- interrupt entry
                    mepc_r   <= trap_pc(31 downto 2) & "00";
                    mcause_r <= MCAUSE_MEI;
                    st_mpie  <= st_mie;
                    st_mie   <= '0';                    -- no nesting
                elsif mret = '1' then                   -- return
                    st_mie   <= st_mpie;
                    st_mpie  <= '1';
                elsif do_write = '1' then
                    case csr_addr is
                        when CSR_MSTATUS =>
                            st_mie  <= new_val(MSTATUS_MIE);
                            st_mpie <= new_val(MSTATUS_MPIE);
                        when CSR_MIE      => meie_r   <= new_val(MIE_MEIE);
                        when CSR_MTVEC    => mtvec_r    <= new_val(31 downto 2) & "00";
                        when CSR_MSCRATCH => mscratch_r <= new_val;
                        when CSR_MEPC     => mepc_r     <= new_val(31 downto 2) & "00";
                        when CSR_MCAUSE   => mcause_r   <= new_val;
                        when others       => null;      -- read-only / not implemented
                    end case;
                end if;
            end if;
        end if;
    end process;

    irq_req <= st_mie and meie_r and ext_irq;
    dbg_bits <= meie_r & st_mpie & st_mie;
    mtvec   <= mtvec_r;
    mepc    <= mepc_r;
end architecture rtl;
