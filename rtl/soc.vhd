-------------------------------------------------------------------------------
-- soc.vhd -- System on chip: core + instruction/data BRAM + peripherals
--
-- Memory map
--   0x0000_0000 - 0x0000_0FFF  IMEM   4 KiB (instruction port only, 1024 words as in the slides)
--   0x0001_0000 - 0x0001_3FFF  DMEM  16 KiB (aliased below 0x8000_0000)
--   0x8000_0000 - 0x8000_00FF  IO    see io_ctrl.vhd
--
-- Pipeline debug mode (SW15 = 1)
--   The CPU is frozen; each press of BTNU advances it by ONE clock cycle.
--   SW14 = 1 additionally advances it automatically (STEP_TICK_CYCLES).
--   7-segment display: word index (PC/4, 2 hex digits) of the instruction in
--     ID | EX | MEM | WB   (left to right); a blank pair = bubble.
--   LEDs: LED15..12 = stage occupied: ID, EX, MEM, WB (off = bubble),
--         LED11 = load-use stall in this cycle, LED10 = flush (mispredicted
--         branch, interrupt or mret), LED9 = interrupt taken in this cycle,
--         LED7..0 = word index of the instruction being fetched (IF).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.riscv_pkg.all;

entity soc is
    generic (
        IMEM_FILE         : string   := "build/imem.hex";
        DMEM_FILE         : string   := "build/dmem.hex";
        IMEM_ADDR_BITS    : natural  := 10;
        DMEM_ADDR_BITS    : natural  := 12;
        CLKS_PER_BIT      : positive := 434;   -- UART: f_clk / baud
        DEBOUNCE_CYCLES   : positive := 500_000; -- buttons: f_clk * 10 ms
        STEP_TICK_CYCLES  : positive := 25_000_000; -- debug auto-step period
        I2C_QUARTER       : positive := 125;        -- I2C: f_clk / (4 x 100 kHz)
        BRANCH_PRED       : boolean  := true;       -- dynamic branch prediction
        USE_ILA           : boolean  := false;      -- ILA core (Vivado IP ila_cpu)
        ILA_WB            : boolean  := false;      -- ILA probes 2/3 = register write in WB
        SEG7_REFRESH_BITS : natural  := 17
    );
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;
        -- board I/O
        switches     : in  std_logic_vector(15 downto 0);
        buttons      : in  std_logic_vector(4 downto 0);
        leds         : out std_logic_vector(15 downto 0);
        seg          : out std_logic_vector(6 downto 0);
        dp           : out std_logic;
        an           : out std_logic_vector(7 downto 0);
        uart_txd     : out std_logic;
        uart_rxd     : in  std_logic := '1';   -- external UART input (Pmod JA1)
        led17_rgb    : out std_logic_vector(2 downto 0);   -- R, G, B of LD17
        tmp_scl      : inout std_logic;                    -- I2C bus of the ADT7420
        tmp_sda      : inout std_logic;                    --   temperature sensor
        -- simulation / debug
        tohost_valid : out std_logic;
        tohost_data  : out word_t;
        dbg_pc_wb    : out word_t;
        dbg_retire   : out std_logic;   -- instruction retired (WB)
        dbg_stall    : out std_logic;   -- load-use bubble inserted
        dbg_flush    : out std_logic;   -- mispredicted branch / jump
        dbg_branch   : out std_logic;   -- branch / jump resolved
        dbg_cpu_en   : out std_logic;   -- CPU clock enable (1 = CPU advanced this cycle)
        dbg_wb_we    : out std_logic;   -- register write in WB (trace)
        dbg_wb_rd    : out std_logic_vector(4 downto 0);
        dbg_wb_data  : out word_t;
        illegal      : out std_logic
    );
end entity soc;

architecture rtl of soc is
    signal imem_addr, imem_rdata : word_t;
    signal dbus_addr, dbus_wdata, dbus_rdata : word_t;
    signal dbus_be   : std_logic_vector(3 downto 0);
    signal dbus_we, dbus_re : std_logic;

    signal io_sel, io_sel_q : std_logic := '0';
    signal dmem_we   : std_logic_vector(3 downto 0);
    signal dmem_rdata, io_rdata : word_t;

    signal retire, stall_evt, flush_evt, branch_evt : std_logic;
    signal seg7_value : word_t;
    signal btn_clean  : std_logic_vector(4 downto 0);
    signal led17      : std_logic;

    -- pipeline debug mode
    signal cpu_en         : std_logic;
    signal dmem_en        : std_logic;
    signal cpu_leds       : std_logic_vector(15 downto 0);
    signal disp_value     : word_t;
    signal disp_enable    : std_logic_vector(7 downto 0);
    signal disp_dp        : std_logic_vector(7 downto 0);
    signal seg7_ctrl      : std_logic_vector(15 downto 0);
    signal sw_dbg_s1, sw_dbg_s2 : std_logic_vector(1 downto 0) := "00";
    signal dbg_mode, dbg_auto   : std_logic;
    signal step_btn_prev  : std_logic := '0';
    signal step_pulse     : std_logic;
    signal tick_cnt       : natural range 0 to STEP_TICK_CYCLES - 1 := 0;
    signal tick           : std_logic;
    signal pc_if, pc_id, pc_ex, pc_mem, pc_wb : word_t;
    signal pipe_valid     : std_logic_vector(3 downto 0);
    signal stall_now, flush_now : std_logic;
    signal irq_now        : std_logic;   -- interrupt taken in this cycle (debug view)
    signal irq_line       : std_logic;   -- interrupt controller -> core
    signal core_csr       : std_logic_vector(2 downto 0);   -- MEIE, MPIE, MIE (ILA)
    signal io_dbg         : std_logic_vector(25 downto 0);  -- UART / irq bits (ILA)
    signal ila_io         : std_logic_vector(31 downto 0);
    signal i2c_scl_o, i2c_sda_o, i2c_scl_i, i2c_sda_i : std_logic;

    -- Integrated Logic Analyzer (Vivado IP "ila_cpu", 5 probes).
    -- Only declared here: with USE_ILA = false (simulation, GHDL) it is never
    -- instantiated, so no IP is needed. The free Vivado licence allows at
    -- most 5 probes, so the signals are packed into 5 buses that read well
    -- in hexadecimal.
    component ila_cpu is
        port (
            clk    : in std_logic;
            probe0 : in std_logic_vector(59 downto 0);   -- PC[11:0] of IF ID EX MEM WB
            probe1 : in std_logic_vector(11 downto 0);   -- status bits
            probe2 : in std_logic_vector(31 downto 0);   -- UART / interrupt bits (ila_io)
            probe3 : in std_logic_vector(31 downto 0);   -- data address
            probe4 : in std_logic_vector(63 downto 0));  -- store data & load data
    end component;
    signal ila_pcs    : std_logic_vector(59 downto 0);
    signal ila_status : std_logic_vector(11 downto 0);
    signal ila_data   : std_logic_vector(63 downto 0);
    signal wb_we      : std_logic;
    signal wb_rd      : std_logic_vector(4 downto 0);
    signal wb_data    : word_t;
    signal ila_wb_rd  : std_logic_vector(31 downto 0);   -- ILA_WB: we & rd
    signal ila_wb_val : std_logic_vector(31 downto 0);   -- ILA_WB: value written
begin

    u_core : entity work.cpu_core
        generic map (BRANCH_PRED => BRANCH_PRED)
        port map (
            clk        => clk,
            rst        => rst,
            en         => cpu_en,
            ext_irq    => irq_line,
            imem_addr  => imem_addr,
            imem_rdata => imem_rdata,
            dbus_addr  => dbus_addr,
            dbus_wdata => dbus_wdata,
            dbus_be    => dbus_be,
            dbus_we    => dbus_we,
            dbus_re    => dbus_re,
            dbus_rdata => dbus_rdata,
            retire     => retire,
            stall_evt  => stall_evt,
            flush_evt  => flush_evt,
            branch_evt => branch_evt,
            dbg_pc_wb  => pc_wb,
            illegal    => illegal,
            dbg_pc_if  => pc_if,
            dbg_pc_id  => pc_id,
            dbg_pc_ex  => pc_ex,
            dbg_pc_mem => pc_mem,
            dbg_valid  => pipe_valid,
            dbg_stall_now => stall_now,
            dbg_flush_now => flush_now,
            dbg_irq_now   => irq_now,
            dbg_csr       => core_csr,
            dbg_wb_we     => wb_we,
            dbg_wb_rd     => wb_rd,
            dbg_wb_data   => wb_data);

    dbg_pc_wb   <= pc_wb;
    dbg_wb_we   <= wb_we;
    dbg_wb_rd   <= wb_rd;
    dbg_wb_data <= wb_data;

    u_imem : entity work.imem
        generic map (ADDR_BITS => IMEM_ADDR_BITS, INIT_FILE => IMEM_FILE)
        port map (clk => clk, addr => imem_addr, rdata => imem_rdata);

    -- address decode
    io_sel  <= dbus_addr(31);
    dmem_we <= dbus_be when dbus_we = '1' and io_sel = '0' else "0000";
    dmem_en <= (not io_sel) and cpu_en;   -- read data held while frozen

    u_dmem : entity work.dmem
        generic map (ADDR_BITS => DMEM_ADDR_BITS, INIT_FILE => DMEM_FILE)
        port map (
            clk   => clk,
            en    => dmem_en,
            we    => dmem_we,
            addr  => dbus_addr,
            wdata => dbus_wdata,
            rdata => dmem_rdata);

    u_io : entity work.io_ctrl
        generic map (CLKS_PER_BIT => CLKS_PER_BIT, DEBOUNCE_CYCLES => DEBOUNCE_CYCLES,
                     I2C_QUARTER => I2C_QUARTER)
        port map (
            clk          => clk,
            rst          => rst,
            sel          => io_sel,
            addr         => dbus_addr(7 downto 0),
            we           => dbus_we,
            re           => dbus_re,
            be           => dbus_be,
            wdata        => dbus_wdata,
            rdata        => io_rdata,
            retire       => retire,
            stall_evt    => stall_evt,
            flush_evt    => flush_evt,
            branch_evt   => branch_evt,
            cpu_en       => cpu_en,
            irq          => irq_line,
            switches     => switches,
            buttons      => buttons,
            buttons_clean=> btn_clean,
            leds         => cpu_leds,
            seg7_value   => seg7_value,
            seg7_ctrl    => seg7_ctrl,
            uart_txd     => uart_txd,
            uart_rxd     => uart_rxd,
            i2c_scl_o    => i2c_scl_o,
            i2c_sda_o    => i2c_sda_o,
            i2c_scl_i    => i2c_scl_i,
            i2c_sda_i    => i2c_sda_i,
            tohost_valid => tohost_valid,
            tohost_data  => tohost_data,
            dbg_io       => io_dbg);

    -- I2C bus: open drain. '0' pulls the line low, otherwise it is released
    -- (high impedance) and the pull-up resistor makes it '1'.
    tmp_scl   <= '0' when i2c_scl_o = '0' else 'Z';
    tmp_sda   <= '0' when i2c_sda_o = '0' else 'Z';
    i2c_scl_i <= '0' when tmp_scl = '0' else '1';
    i2c_sda_i <= '0' when tmp_sda = '0' else '1';

    -- read data mux (select registered alongside the memories)
    process (clk)
    begin
        if rising_edge(clk) then
            if cpu_en = '1' then
                io_sel_q <= io_sel;
            end if;
        end if;
    end process;

    dbus_rdata <= io_rdata when io_sel_q = '1' else dmem_rdata;

    dbg_retire <= retire;
    dbg_stall  <= stall_evt;
    dbg_flush  <= flush_evt;
    dbg_branch <= branch_evt;
    dbg_cpu_en <= cpu_en;

    ---------------------------------------------------------------------------
    -- Pipeline debug mode: single step (BTNU) / slow motion (SW14)
    ---------------------------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            sw_dbg_s1     <= switches(15 downto 14);   -- synchronise switches
            sw_dbg_s2     <= sw_dbg_s1;
            step_btn_prev <= btn_clean(1);             -- BTNU, debounced
            if rst = '1' or tick_cnt = STEP_TICK_CYCLES - 1 then
                tick_cnt <= 0;
            else
                tick_cnt <= tick_cnt + 1;
            end if;
        end if;
    end process;

    dbg_mode   <= sw_dbg_s2(1);
    dbg_auto   <= sw_dbg_s2(0);
    step_pulse <= btn_clean(1) and not step_btn_prev;  -- one cycle per press
    tick       <= '1' when tick_cnt = STEP_TICK_CYCLES - 1 else '0';
    cpu_en     <= '1' when dbg_mode = '0' else step_pulse or (dbg_auto and tick);

    -- outputs: normal view (written by the program) or pipeline view
    leds <= cpu_leds when dbg_mode = '0' else
            pipe_valid &                     -- LED15..12: ID, EX, MEM, WB occupied
            stall_now & flush_now & irq_now & '0' &   -- LED11 stall, LED10 flush, LED9 interrupt
            pc_if(9 downto 2);               -- LED7..0: instruction in IF

    disp_value  <= seg7_value when dbg_mode = '0' else
                   pc_id(9 downto 2) & pc_ex(9 downto 2) & pc_mem(9 downto 2) & pc_wb(9 downto 2);
    disp_dp     <= seg7_ctrl(15 downto 8) when dbg_mode = '0' else x"00";
    disp_enable <= seg7_ctrl(7 downto 0) when dbg_mode = '0' else
                   pipe_valid(3) & pipe_valid(3) & pipe_valid(2) & pipe_valid(2) &
                   pipe_valid(1) & pipe_valid(1) & pipe_valid(0) & pipe_valid(0);

    ---------------------------------------------------------------------------
    -- LD17: each press of BTNR (bit 3, debounced) toggles the green LED.
    -- Pure hardware, independent of the CPU: a direct demo of the debouncer.
    ---------------------------------------------------------------------------
    u_led17 : entity work.led_toggle
        port map (clk => clk, rst => rst, btn => btn_clean(3), led => led17);

    led17_rgb <= '0' & led17 & '0';   -- R off, G = toggle, B off

    u_seg7 : entity work.seg7_driver
        generic map (REFRESH_BITS => SEG7_REFRESH_BITS)
        port map (
            clk    => clk,
            rst    => rst,
            value  => disp_value,
            enable => disp_enable,
            dp_en  => disp_dp,
            seg    => seg,
            dp     => dp,
            an     => an);

    ---------------------------------------------------------------------------
    -- ILA: records the pipeline inside the FPGA (Hardware Manager waveforms)
    ---------------------------------------------------------------------------
    -- probe0: 5 x 3 hex digits = the byte address (PC[11:0]) in each stage,
    --         left to right IF ID EX MEM WB
    ila_pcs <= pc_if(11 downto 0) & pc_id(11 downto 0) & pc_ex(11 downto 0)
             & pc_mem(11 downto 0) & pc_wb(11 downto 0);
    -- probe1, bit 11..0: valid ID EX MEM WB | stall flush irq_taken retire |
    --                    cpu_en irq_line store load
    ila_status <= pipe_valid & stall_now & flush_now & irq_now & retire
                & cpu_en & irq_line & dbus_we & dbus_re;
    -- probe2: UART receiver, interrupt controller and CSR bits, bit by bit
    --   0 RX line  2..1 rx state (00 IDLE 01 START 10 DATA 11 STOP)
    --   5..3 bit number  13..6 shift register  14 byte valid  15 RX FIFO empty
    --   16 FIFO read  20..17 IRQ_PENDING  24..21 IRQ_ENABLE  25 irq line
    --   26 MIE  27 MPIE  28 MEIE
    ila_io <= "000" & core_csr & io_dbg;
    -- probe4: first 8 hex digits = store data (EX), last 8 = load data (MEM)
    ila_data <= dbus_wdata & dbus_rdata;

    -- ILA_WB = true: probes 2 and 3 show the register write of the instruction
    -- in WB instead, to compare the board with the simulation trace:
    --   probe2 (ila_wb_val) = value written
    --   probe3 (ila_wb_rd)  = bit 5 write enable, bits 4..0 rd  (hex 2X = xX)
    ila_wb_val <= wb_data;
    ila_wb_rd  <= x"000000" & "00" & wb_we & wb_rd;

    g_ila : if USE_ILA and not ILA_WB generate
        u_ila : ila_cpu
            port map (
                clk    => clk,
                probe0 => ila_pcs,
                probe1 => ila_status,
                probe2 => ila_io,
                probe3 => dbus_addr,
                probe4 => ila_data);
    end generate;

    g_ila_wb : if USE_ILA and ILA_WB generate
        u_ila : ila_cpu
            port map (
                clk    => clk,
                probe0 => ila_pcs,
                probe1 => ila_status,
                probe2 => ila_wb_val,
                probe3 => ila_wb_rd,
                probe4 => ila_data);
    end generate;

end architecture rtl;
