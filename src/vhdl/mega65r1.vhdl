----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date:    22:30:37 12/10/2013 
-- Design Name: 
-- Module Name:    container - Behavioral 
-- Project Name: 
-- Target Devices: 
-- Tool versions: 
-- Description: 
--
-- Dependencies: 
--
-- Revision: 
-- Revision 0.01 - File Created
-- Additional Comments: 
--
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use Std.TextIO.all;


-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx primitives in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity container is
  Port ( CLK_IN : STD_LOGIC;         
         btnCpuReset : in  STD_LOGIC;
--         irq : in  STD_LOGIC;
--         nmi : in  STD_LOGIC;
         
         ----------------------------------------------------------------------
         -- CIA1 ports for keyboard/joystick 
         ----------------------------------------------------------------------
         restore_key : in std_logic;
         column : inout  std_logic_vector(8 downto 0);
         row : inout  std_logic_vector(8 downto 0);
         fa_left : in std_logic;
         fa_right : in std_logic;
         fa_up : in std_logic;
         fa_down : in std_logic;
         fa_fire : in std_logic;
         fb_left : in std_logic;
         fb_right : in std_logic;
         fb_up : in std_logic;
         fb_down : in std_logic;
         fb_fire : in std_logic;
         
         ----------------------------------------------------------------------
         -- VGA output
         ----------------------------------------------------------------------
         vdac_clk : out std_logic;
         vdac_sync_n : out std_logic; -- tie low
         vdac_blank_n : out std_logic; -- tie high
         vsync : out  STD_LOGIC;
         hsync : out  STD_LOGIC;
         vgared : out  UNSIGNED (7 downto 0);
         vgagreen : out  UNSIGNED (7 downto 0);
         vgablue : out  UNSIGNED (7 downto 0);

         hdmi_vsync : out  STD_LOGIC;
         hdmi_hsync : out  STD_LOGIC;
         hdmired : out  UNSIGNED (7 downto 0);
         hdmigreen : out  UNSIGNED (7 downto 0);
         hdmiblue : out  UNSIGNED (7 downto 0);
         hdmi_spdif : in std_logic;
         hdmi_spdif_out : out std_logic;
         hdmi_scl : out std_logic;
         hdmi_sda : out std_logic;
         hdmi_de : out std_logic; -- high when valid pixels being output
         -- (i.e., when hsync, vsync both low?)
         
         
         ---------------------------------------------------------------------------
         -- IO lines to the ethernet controller
         ---------------------------------------------------------------------------
         eth_mdio : inout std_logic;
         eth_mdc : out std_logic;
         eth_reset : out std_logic;
         eth_rxd : in unsigned(1 downto 0);
         eth_txd : out unsigned(1 downto 0);
         eth_rxer : in std_logic;
         eth_txen : out std_logic;
         eth_rxdv : in std_logic;
         eth_interrupt : in std_logic;
         eth_clock : out std_logic;
         
         -------------------------------------------------------------------------
         -- Lines for the SDcard interface itself
         -------------------------------------------------------------------------
         sdReset : out std_logic := '0';  -- must be 0 to power SD controller (cs_bo)
         sdClock : out std_logic;       -- (sclk_o)
         sdMOSI : out std_logic;      
         sdMISO : in  std_logic;

         -- Left and right audio
         pwm_l : out std_logic;
         pwm_r : out std_logic;
         
         ----------------------------------------------------------------------
         -- PS/2 keyboard interface
         ----------------------------------------------------------------------
         -- ps2clk : in std_logic;
         -- ps2data : in std_logic;

         flopled : out std_logic;
         
         ----------------------------------------------------------------------
         -- Debug interfaces on Nexys4 board
         ----------------------------------------------------------------------
         UART_TXD : out std_logic;
         RsRx : in std_logic
         
         );
end container;

architecture Behavioral of container is

  component dotclock is
    port (
      CLK_IN1           : in     std_logic;
    -- Clock out ports
    CLK_OUT1          : out    std_logic;
    CLK_OUT2          : out    std_logic;
    CLK_OUT3          : out    std_logic;
    CPUCLOCK          : out    std_logic;
--    IOCLOCK          : out    std_logic;
    PIX2CLOCK          : out    std_logic
      );
  end component;

  component fpgatemp is
    Generic ( DELAY_CYCLES : natural := 480 ); -- 10us @ 48 Mhz
    Port ( clk : in  STD_LOGIC;
           rst : in  STD_LOGIC;
           temp : out  STD_LOGIC_VECTOR (11 downto 0));
  end component;
  
  signal irq : std_logic := '1';
  signal nmi : std_logic := '1';
  
  signal pixelclock : std_logic;
  signal pixelclock2x : std_logic;
  signal cpuclock : std_logic;
--  signal ioclock : std_logic;
  
  signal segled_counter : unsigned(31 downto 0) := (others => '0');

  signal clock100mhz : std_logic := '0';
  signal clock50mhz : std_logic := '0';

  signal slowram_addr :    std_logic_vector(26 downto 0);
  signal slowram_addr_reflect :    std_logic_vector(26 downto 0);
  signal slowram_we :      std_logic;
  signal slowram_request_toggle :      std_logic;
  signal slowram_done_toggle :      std_logic;
  signal slowram_datain :  std_logic_vector(7 downto 0);
  signal slowram_datain_reflect : std_logic_vector(7 downto 0);
  signal cache_address : std_logic_vector(8 downto 0);
  signal cache_read_data : std_logic_vector(150 downto 0);
  signal ddr_state : unsigned(7 downto 0);
  signal ddr_counter : unsigned(7 downto 0);

  signal v_hsync : std_logic;
  signal v_vsync : std_logic;
  signal v_red : unsigned(7 downto 0);
  signal v_green : unsigned(7 downto 0);
  signal v_blue : unsigned(7 downto 0);
  signal v_de : std_logic;
  
  -- XXX We should read the real temperature and feed this to the DDR controller
  -- so that it can update timing whenever the temperature changes too much.
  signal fpga_temperature : std_logic_vector(11 downto 0) := (others => '0');
  
begin
  
  dotclock1: component dotclock
    port map ( clk_in1 => CLK_IN,
               clk_out1 => clock100mhz,
               -- CLK_OUT2 is good for 1920x1200@60Hz, CLK_OUT3___160
               -- for 1600x1200@60Hz
               -- 60Hz works fine, but 50Hz is not well supported by monitors. 
               -- so I guess we will go with an NTSC-style 60Hz display.       
               -- For C64 mode it would be nice to have PAL or NTSC selectable.                    -- Perhaps consider a different video mode for that, or buffering
               -- the generated frames somewhere?
               clk_out2 => pixelclock,
               clk_out3 => cpuclock, -- 48MHz
               PIX2CLOCK => pixelclock2x
--               clk_out3 => ioclock -- also 48MHz
               );

  fpgatemp0: fpgatemp
    generic map (DELAY_CYCLES => 480)
    port map (
      rst => '0',
      clk => cpuclock,
      temp => fpga_temperature);
    
  machine0: machine
    port map (
      pixelclock      => pixelclock,
      pixelclock2x      => pixelclock2x,
      cpuclock        => cpuclock,
      clock50mhz      => clock50mhz,
--      ioclock         => ioclock, -- 32MHz
--      uartclock         => ioclock, -- must be 32MHz
      uartclock         => cpuclock, -- Match CPU clock (48MHz)
      ioclock         => cpuclock, -- Match CPU clock
      btncpureset => btncpureset,
      irq => irq,
      nmi => nmi,

      no_kickstart => '0',
      ddr_counter => ddr_counter,
      ddr_state => ddr_state,
      
      vsync           => v_vsync,
      hsync           => v_hsync,
      vgared          => v_red,
      vgagreen        => v_green,
      vgablue         => v_blue,

      porta_pins => column(7 downto 0),
      portb_pins => row(7 downto 0),
      keyboard_column8 => column(8),
      keyboard_capslock => row(8),
      
      ---------------------------------------------------------------------------
      -- IO lines to the ethernet controller
      ---------------------------------------------------------------------------
      eth_mdio => eth_mdio,
      eth_mdc => eth_mdc,
      eth_reset => eth_reset,
      eth_rxd => eth_rxd,
      eth_txd => eth_txd,
      eth_txen => eth_txen,
      eth_rxer => eth_rxer,
      eth_rxdv => eth_rxdv,
      eth_interrupt => eth_interrupt,
      
      -------------------------------------------------------------------------
      -- Lines for the SDcard interface itself
      -------------------------------------------------------------------------
      cs_bo => sdReset,
      sclk_o => sdClock,
      mosi_o => sdMOSI,
      miso_i => sdMISO,

      aclMISO => aclMISO,
      aclMOSI => aclMOSI,
      aclSS => aclSS,
      aclSCK => aclSCK,
      aclInt1 => aclInt1,
      aclInt2 => aclInt2,
    
      micData => micData,
      micClk => micClk,
      micLRSel => micLRSel,

      ampPWM_l => pwm_l,
      ampPWM_r => pwm_r,
          
      ps2data =>      ps2data,
      ps2clock =>     ps2clk,

      fpga_temperature => fpga_temperature,
      
      UART_TXD => UART_TXD,
      RsRx => RsRx,

      -- Ignore widget board interface
      pmod_clock => '1'
         
      );

  
  -- Hardware buttons for triggering IRQ & NMI
  nmi <= not restore_key;

  -- Generate 50MHz clock for ethernet
  process (clock100mhz) is
  begin
    if rising_edge(clock100mhz) then
      report "50MHz tick";
      clock50mhz <= not clock50mhz;
      eth_clock <= not clock50mhz;
    end if;
  end process;
  
  process (pixelclock) is
  begin
    vdac_clk <= pixelclock;
    vdac_sync_n <= '0';  -- no sync on green
    vdac_blank_n <= not (v_hsync or v_vsync); 
    if rising_edge(pixelclock) then
      vga_hsync <= v_hsync;
      vga_vsync <= v_vsync;
      vgared <= v_red;
      vgagreen <= v_green;
      vgablue <= v_blue;

      hdmi_hsync <= v_hsync;
      hdmi_vsync <= v_vsync;
      hdmired <= v_red;
      hdmigreen <= v_green;
      hdmiblue <= v_blue;
      -- pixels valid only when neither sync signal is asserted
      hdmi_de <= not (v_hsync or v_vsync);
      -- no hdmi audio yet
      hdmi_spdif_out <= 'Z';
      -- HDMI control interface
      -- XXX We need to send some commands via I2C to configure the HDMI
      -- interface, which we don't yet do, so HDMI output will not yet work.
      hdmi_scl <= 'Z';
      hdmi_sda <= 'Z';
    end if;
  end process;    
  
end Behavioral;