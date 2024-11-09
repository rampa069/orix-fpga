library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity DS1501 is
    Port (
        CLK           : in  STD_LOGIC;
        RESETn        : in  STD_LOGIC;
        ADDR          : in  STD_LOGIC_VECTOR(2 downto 0);
        RTC           : in  STD_LOGIC_VECTOR(63 downto 0);
        DATA_OUT      : out STD_LOGIC_VECTOR(7 downto 0)
    );
end DS1501;

architecture Behavioral of DS1501 is
    signal SECONDS : STD_LOGIC_VECTOR(7 downto 0);
    signal MINUTES : STD_LOGIC_VECTOR(7 downto 0);
    signal HOURS   : STD_LOGIC_VECTOR(7 downto 0);
    signal DAY     : STD_LOGIC_VECTOR(7 downto 0);
	 signal DATE    : STD_LOGIC_VECTOR(7 downto 0);
    signal MONTH   : STD_LOGIC_VECTOR(7 downto 0);
    signal YEAR    : STD_LOGIC_VECTOR(7 downto 0);
	 signal CENTURY : STD_LOGIC_VECTOR(7 downto 0);

begin
    process (CLK, RESETn)
    begin
        if (RESETn = '0') then
            SECONDS <= (others => '0');
            MINUTES <= (others => '0');
            HOURS   <= (others => '0');
            DAY     <= (others => '0');
				DATE    <= (others => '0');
            MONTH   <= (others => '0');
            YEAR    <= (others => '0');
            CENTURY <= (others => '0');
        elsif rising_edge(CLK) then
            -- Extract each time and date component from the input vector
            SECONDS <= RTC(7 downto 0);
            MINUTES <= RTC(15 downto 8);
            HOURS   <= RTC(23 downto 16);
            DAY     <= RTC(55 downto 48);
				DATE    <= RTC(31 downto 24);
            MONTH   <= RTC(39 downto 32);
            YEAR    <= RTC(47 downto 40);
				CENTURY <= RTC(63 downto 56);
        end if;
    end process;

    process (ADDR, SECONDS, MINUTES, HOURS, DAY, DATE, MONTH, YEAR, CENTURY)
    begin
        case ADDR is
            when "000" =>
                DATA_OUT <= SECONDS;
            when "001" =>
                DATA_OUT <= MINUTES;
            when "010" =>
                DATA_OUT <= HOURS;
            when "011" =>
                DATA_OUT <= DAY;
            when "100" =>
                DATA_OUT <= DATE;
            when "101" =>
                DATA_OUT <= MONTH;
            when "110" =>
                DATA_OUT <= YEAR;
            when "111" =>
                DATA_OUT <= x"20"; --CENTURY;
            when others =>
                DATA_OUT <= (others => '1');
        end case;
    end process;

end Behavioral;