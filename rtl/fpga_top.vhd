-------------------------------------------------------------------------------
-- fpga_top.vhd -- Board top level (Xilinx 7-series: Artix-7 / Zynq-7000)
--
-- * MMCM generates the core clock from the 100 MHz board oscillator.
--   Change CORE_CLK_MHZ to explore timing (VCO = 1000 MHz, so any value
--   for which 1000/CORE_CLK_MHZ is a multiple of 0.125 works: 25, 40, 50,
--   80, 100 ...).
-- * Asynchronous active-low reset button is synchronised to the core clock
--   and held until the MMCM locks.
-- Port names follow the Digilent Nexys A7 / Nexys4-DDR master XDC.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.riscv_pkg.all;

library unisim;
use unisim.vcomponents.all;

entity fpga_top is
    generic (
        CORE_CLK_MHZ : natural := 50;
        BAUD_RATE    : natural := 115200;
        DEBOUNCE_MS  : natural := 10;
        STEP_HZ      : natural := 2;     -- debug slow-motion speed (SW15+SW14)
        BRANCH_PRED  : boolean := true;  -- false = always predict not-taken
        USE_ILA      : boolean := false; -- true = ILA inside the FPGA (Vivado IP ila_cpu)
        ILA_WB       : boolean := false; -- true = ILA probes 2/3 = register write in WB
        IMEM_FILE    : string  := "imem.hex";
        DMEM_FILE    : string  := "dmem.hex"
    );
    port (
        CLK100MHZ    : in  std_logic;
        CPU_RESETN   : in  std_logic;
        SW           : in  std_logic_vector(15 downto 0);
        BTNC, BTNU, BTNL, BTNR, BTND : in std_logic;
        LED          : out std_logic_vector(15 downto 0);
        SEG          : out std_logic_vector(6 downto 0);   -- CG..CA
        DP           : out std_logic;
        AN           : out std_logic_vector(7 downto 0);
        UART_RXD_OUT : out std_logic;                       -- FPGA -> PC
        UART_EXT_RX  : in  std_logic;                       -- Pmod JA1 <- ESP32 TX
        LED17_R, LED17_G, LED17_B : out std_logic;          -- RGB LED LD17
        TMP_SCL, TMP_SDA : inout std_logic                  -- ADT7420 temperature sensor (I2C)
    );
end entity fpga_top;

architecture rtl of fpga_top is
    signal clk_fb, clk_fb_buf : std_logic;
    signal clk_core_unbuf     : std_logic;
    signal clk                : std_logic;
    signal locked             : std_logic;
    signal rst_meta, rst_sync : std_logic := '1';
    signal buttons            : std_logic_vector(4 downto 0);
    signal led17_rgb          : std_logic_vector(2 downto 0);
begin

    u_mmcm : MMCME2_BASE
        generic map (
            CLKIN1_PERIOD    => 10.0,
            DIVCLK_DIVIDE    => 1,
            CLKFBOUT_MULT_F  => 10.0,
            CLKOUT0_DIVIDE_F => 1000.0 / real(CORE_CLK_MHZ))
        port map (
            CLKIN1   => CLK100MHZ,
            CLKFBIN  => clk_fb_buf,
            CLKFBOUT => clk_fb,
            CLKOUT0  => clk_core_unbuf,
            LOCKED   => locked,
            PWRDWN   => '0',
            RST      => '0');

    u_bufg_fb  : BUFG port map (I => clk_fb,         O => clk_fb_buf);
    u_bufg_clk : BUFG port map (I => clk_core_unbuf, O => clk);

    -- reset synchroniser (asserted asynchronously, released synchronously)
    process (clk, CPU_RESETN, locked)
    begin
        if CPU_RESETN = '0' or locked = '0' then
            rst_meta <= '1';
            rst_sync <= '1';
        elsif rising_edge(clk) then
            rst_meta <= '0';
            rst_sync <= rst_meta;
        end if;
    end process;

    buttons <= BTND & BTNR & BTNL & BTNU & BTNC;

    u_soc : entity work.soc
        generic map (
            IMEM_FILE         => IMEM_FILE,
            DMEM_FILE         => DMEM_FILE,
            CLKS_PER_BIT      => (CORE_CLK_MHZ * 1_000_000) / BAUD_RATE,
            DEBOUNCE_CYCLES   => CORE_CLK_MHZ * 1_000 * DEBOUNCE_MS,
            STEP_TICK_CYCLES  => (CORE_CLK_MHZ * 1_000_000) / STEP_HZ,
            I2C_QUARTER       => (CORE_CLK_MHZ * 5) / 2,   -- 100 kHz SCL
            BRANCH_PRED       => BRANCH_PRED,
            USE_ILA           => USE_ILA,
            ILA_WB            => ILA_WB,
            SEG7_REFRESH_BITS => 17)
        port map (
            clk          => clk,
            rst          => rst_sync,
            switches     => SW,
            buttons      => buttons,
            leds         => LED,
            seg          => SEG,
            dp           => DP,
            an           => AN,
            uart_txd     => UART_RXD_OUT,
            uart_rxd     => UART_EXT_RX,
            led17_rgb    => led17_rgb,
            tmp_scl      => TMP_SCL,
            tmp_sda      => TMP_SDA,
            tohost_valid => open,
            tohost_data  => open);

    LED17_R <= led17_rgb(2);
    LED17_G <= led17_rgb(1);
    LED17_B <= led17_rgb(0);

end architecture rtl;
