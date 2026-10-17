library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ch376_interface is
    port (
        clk         : in  std_logic;
		  PH2         : in std_logic;                      -- 6502 PH2 
        reset_n     : in  std_logic;
        ena         : in  std_logic := '1';             -- '0' keeps the CH376 bus idle (backend not selected)
        addr        : in  std_logic_vector(15 downto 0); -- Processor address
        data_in     : in  std_logic_vector(7 downto 0);  -- Data from the processor to the CH376
        data_out    : out std_logic_vector(7 downto 0);  -- Data from the CH376 to the processor
        data        : inout std_logic_vector(7 downto 0); -- Bidirectional data bus to the CH376
        RnW         : in  std_logic;                    -- Read/Write signal from the 6502 (1 = read, 0 = write)
        cs340n      : in  std_logic;                    -- External chip select (active low)
		  cs          : out std_logic;
        wr          : out std_logic;                    -- Write signal to the CH376
        rd          : out std_logic;                    -- Read signal to the CH376
        a0          : out std_logic                     -- A0 line to the CH376
    );
end entity;

architecture Behavioral of ch376_interface is
    signal data_buffer : std_logic_vector(7 downto 0);
    signal dir         : std_logic; -- Bus direction: '1' = write, '0' = read
	 signal cs340n_int  : std_logic; -- Internal chip select (active low)
	 
    signal PH2_cntr : std_logic_vector(5 downto 0) := "000000"; -- 6-bit counter
    signal PH2_old  : std_logic_vector(3 downto 0) := "0000";   -- To track PH2 transitions
    signal PH2_1    : std_logic := '0';                         -- Derived clock signal 1
    signal PH2_2    : std_logic := '0';                         -- Derived clock signal 2
    signal PH2_3    : std_logic := '0';                         -- Derived clock signal 3

begin

    process(addr, ena)
    begin
        if (addr = x"0340" or addr = x"0341") and ena = '1' then
            cs340n_int <= '0'; -- Chip select active
        else
            cs340n_int <= '1'; -- Chip select inactive
        end if;
    end process;
	 
    -- Generation of RD, WR, and A0
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            rd <= '1';
            wr <= '1';
				cs <= '1';
            a0 <= '0';
        elsif rising_edge(clk) then
            if cs340n_int = '0' then -- CS active low
                a0 <= addr(0); -- Least significant bit of the address

                if RnW = '0' then
                    wr <= '0';
                    rd <= '1';
						  cs  <= '0';
                    dir <= '1'; -- Write
                else
                    wr <= '1';
                    rd <= '0';
                    dir <= '0'; -- Read
						  cs  <= '0';
                end if;
            else
                wr <= '1';
                rd <= '1';
					 cs  <='1';
            end if;
        end if;
    end process;

    -- Data bus handling
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            data_buffer <= (others => '0');
            data_out <= (others => '0');
        elsif rising_edge(clk) then
            if cs340n_int = '0' then
                if RnW = '0' then
                    data_buffer <= data_in;
                else
                    data_out <= data;
                end if;
            end if;
        end if;
    end process;

    -- Connection to the bidirectional bus
    data <= data_buffer when (cs340n_int = '0' and RnW = '0') else (others => 'Z');
	 
	 
 -- PH2 derived clocks for 24 MHz.
    process (PH2, CLK)
    begin
        if reset_n = '0' then
            PH2_cntr <= "000000"; -- Ajuste del tamaño del contador a 6 bits
        elsif falling_edge(CLK) then 
            PH2_old <= PH2_old(2 downto 0) & PH2;
            if (PH2_old = "1111") and (PH2 = '0') then 
                PH2_cntr <= "000000";
                PH2_1 <= '1';
            else
					 PH2_cntr <= std_logic_vector(unsigned(PH2_cntr) + 1); -- Conversión aritmética
                
                if (PH2_cntr = "110010") then -- Ajustado de 16 (10000) a 50 (110010)
                    PH2_1 <= '0';
                    PH2_2 <= '1';
                elsif (PH2_cntr = "111011") then -- Ajustado de 23 (10111) a 59 (111011)
                    PH2_3 <= '1';
                elsif (PH2_cntr = "111110") then -- Ajustado de 28 (11100) a 62 (111110)
                    PH2_2 <= '0';                   
                elsif (PH2_cntr = "111111") then -- Ajustado de 29 (11101) a 63 (111111)
                    PH2_3 <= '0';
                end if;
            end if;
        end if;
    end process;
end architecture;

