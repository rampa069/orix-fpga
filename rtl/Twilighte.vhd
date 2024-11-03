library ieee;
use ieee.std_logic_1164.all;

entity Twilighte is

port(

CLK              : in std_logic;
ADDR             : in std_logic_vector(7 downto 0);
R_W              : in std_logic;
NMI              : inout  std_logic;
nRESET           : in std_logic;


CS314n           : in std_logic;   -- VIA
CS340n           : in std_logic;   -- CH376 activation
CS342n           : in std_logic;   -- Twilighte register
CS343n           : in std_logic;   -- Twilighte Banking
 

PA               : in std_logic_vector(7 downto 0);
DB_IN            : in  std_logic_vector(7 downto 0);
DB_OUT           : out std_logic_vector(7 downto 0);

BANK0_ROMRAM     : out std_logic; 
BANK1_ROMRAM     : out std_logic; 
BANK2_ROMRAM     : out std_logic; 
BANK3_ROMRAM     : out std_logic; 
BANK4_ROMRAM     : out std_logic 
);

end Twilighte;
architecture EXTENSION of Twilighte is

signal start   : std_logic;
signal u16k    : std_logic;
signal isRamOverlaySelected : std_logic;

signal write_314_detected   : std_logic;
signal register_314         : std_logic_vector (7 downto 0);

signal twilighte_register           : std_logic_vector (7 downto 0);
signal twilighte_banking_register   : std_logic_vector (7 downto 0);
signal nmiFromTwilighteBoard        : std_logic;


begin


reset : process (nRESET, pa, u16k)
begin
    if (nRESET = '0') then
        BANK0_ROMRAM <= '0';
        BANK1_ROMRAM <= '1';
        BANK2_ROMRAM <= '1';
        BANK3_ROMRAM <= '0';
        BANK4_ROMRAM <= '0';
        start <= '0';
        isRamOverlaySelected <= '1';
    else
        if (start = '0') then
            BANK0_ROMRAM <= '0';
            BANK1_ROMRAM <= '1';
            BANK2_ROMRAM <= '1';      
            BANK3_ROMRAM <= '0';
            BANK4_ROMRAM <= '0';
            isRamOverlaySelected <= '1';
            if pa(2 downto 0) = "111" then
                start <= '1';
            end if;
        elsif (write_314_detected = '0') then
            if register_314(1) = '0' then  -- Activate RAM overlay
                BANK0_ROMRAM <= '1';
                BANK1_ROMRAM <= '1';
                BANK2_ROMRAM <= '1';
                BANK3_ROMRAM <= '0';
                BANK4_ROMRAM <= '0';
                isRamOverlaySelected <= '0';
            else
                BANK0_ROMRAM <= '1';
                BANK1_ROMRAM <= '0';
                BANK2_ROMRAM <= '1';
                BANK3_ROMRAM <= '0';
                BANK4_ROMRAM <= '0';
                isRamOverlaySelected <= '1';
            end if;
        else
            case pa(2 downto 0) is
                when "111" =>
                    BANK0_ROMRAM <= '0';
                    BANK1_ROMRAM <= '1';
                    BANK2_ROMRAM <= '1';
                when "110" =>
                    BANK0_ROMRAM <= '1';
                    BANK1_ROMRAM <= '0';
                    BANK2_ROMRAM <= '1';
                when "101" =>
                    BANK0_ROMRAM <= '0';
                    BANK1_ROMRAM <= '0';
                    BANK2_ROMRAM <= '1';
                when "100" =>
                    BANK0_ROMRAM <= '1';
                    BANK1_ROMRAM <= '1';
                    BANK2_ROMRAM <= '0';
                when "011" =>
                    BANK0_ROMRAM <= '0';
                    BANK1_ROMRAM <= '1';
                    BANK2_ROMRAM <= '0';
                when "010" =>
                    BANK0_ROMRAM <= '1';
                    BANK1_ROMRAM <= '0';
                    BANK2_ROMRAM <= '0';
                when "001" =>
                    BANK0_ROMRAM <= '0';
                    BANK1_ROMRAM <= '0';
                    BANK2_ROMRAM <= '0';
                when others =>
                    BANK0_ROMRAM <= '1';
                    BANK1_ROMRAM <= '1';
                    BANK2_ROMRAM <= '1';
                    isRamOverlaySelected <= '0';
            end case;

            if twilighte_register(4) = '1' then  -- Telestrat emulation
                isRamOverlaySelected <= '0';
            else
                isRamOverlaySelected <= '1';
            end if;

            if ((pa(2 downto 0) = "100") or (pa(2 downto 0) = "011") or (pa(2 downto 0) = "010") or (pa(2 downto 0) = "001")) then
                BANK3_ROMRAM <= twilighte_banking_register(0);
                BANK4_ROMRAM <= twilighte_banking_register(1);
                if (twilighte_banking_register(2) = '1') then
                    case pa(2 downto 0) is
                        when "100" =>
                            BANK0_ROMRAM <= '1';
                            BANK1_ROMRAM <= '1';
                            BANK2_ROMRAM <= '1';
                        when "011" =>
                            BANK0_ROMRAM <= '0';
                            BANK1_ROMRAM <= '1';
                            BANK2_ROMRAM <= '1';
                        when "010" =>
                            BANK0_ROMRAM <= '1';
                            BANK1_ROMRAM <= '0';
                            BANK2_ROMRAM <= '1';
                        when "001" =>
                            BANK0_ROMRAM <= '0';
                            BANK1_ROMRAM <= '0';
                            BANK2_ROMRAM <= '1';
                        when others => null;
                    end case;
                end if;
                isRamOverlaySelected <= not twilighte_register(5);
            else
                BANK3_ROMRAM <= '0';
                BANK4_ROMRAM <= '0';
            end if;
        end if;
    end if;
end process;


process (R_W,clk,nRESET )
begin
				if    CS342n = '0'  and R_W = '1' then
							 DB_OUT <= twilighte_register;
				elsif CS342n = '0'  and R_W = '1' then
							 DB_OUT <= twilighte_banking_register;	
				else 
						DB_OUT <= "ZZZZZZZZ";
				end if;
				
				if (nRESET='0') then 
				end if;
end process;					

   process (nRESET,twilighte_register,CS342n,CS343n,CS314n,ADDR, R_W, DB_IN,clk,CS340n,NMI)
    begin
         if nRESET = '0'  then
               twilighte_register <= "10000011";
					twilighte_banking_register <="00000000";
					write_314_detected <='1';
					register_314 <= "00000000";
					nmiFromTwilighteBoard <='0';
	   	elsif falling_edge(CLK) then
					if CS342n = '0'  and R_W = '0' then
							twilighte_register <= DB_IN; -- EEPROM register

					elsif CS343n = '0'  and R_W = '0' then
							twilighte_banking_register <= DB_IN;
					elsif cs314n = '0'  and R_W = '0' then
							register_314 <= DB_IN ;
							if register_314(1)='0' then
								write_314_detected <='0';
							end if;

						   DB_OUT <= "ZZZZZZZZ";
					end if;

        end if;
    end process;	

end EXTENSION;