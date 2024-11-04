library ieee;
use ieee.std_logic_1164.all;
-- ------------------------------------------------------------------
-- TODO in the future : 
-- Twilighte register
--      b0 : VERSion
--      b1 : VERSION
--      b2 : version 
--      b3 : exit to emulation mode ??
--      b4 : telestrat harware emulation ? 
--      b5 : 1 switch to RAM, 0 to eeprom   
--      b6 : jasmin hardware register TODO  ?
--      b7 : microdisc hardware register TODO 

-- Le numero de version doit être en IN uniquement et non pas en inout
-- ------------------------------------------------------------------


-- Register for twilighte card (current)
--      b0 : VERSION
--      b1 : VERSION
--      b2 : NA 
--      b3 : NA
--      b4 : NA
--      b5 : 1 switch to RAM, 0 to eeprom 
--      b6 : NA
--      b7 : NA

entity Twilighte is

port(

CLK              : in std_logic;
ADDR             : in std_logic_vector(7 downto 0);
R_W              : in std_logic;
NMI              : inout  std_logic;
nRESET           : in std_logic;
nMAP             : in std_logic;


CS314n           : in std_logic;   -- VIA
CS340n           : in std_logic;   -- CH376 activation
CS342n           : in std_logic;   -- Twilighte register
CS343n           : in std_logic;   -- Twilighte Banking
 

PA               : in std_logic_vector(7 downto 0);
DB_IN            : in  std_logic_vector(7 downto 0);
DB_OUT           : out std_logic_vector(7 downto 0);

BANK             : out std_logic_vector(4 downto 0);
ISRAM            : out std_logic
);

end Twilighte;
architecture EXTENSION of Twilighte is

signal start                        : std_logic;
signal isRamOverlaySelected         : std_logic;
signal register_314                 : std_logic_vector (7 downto 0);
signal twilighte_register           : std_logic_vector (7 downto 0);
signal twilighte_banking_register   : std_logic_vector (7 downto 0);
signal nmiFromTwilighteBoard        : std_logic;

begin


--ISRAM <= '1' when isRamOverlaySelected = '0' and nMAP ='0'  else '0';
ISRAM <= '1' when nMAP ='0'  else '0';

reset : process (nRESET, pa)
begin
    if (nRESET = '0') then
	     BANK <= "00110";
        start <= '0';
        isRamOverlaySelected <= '1';
    else
        if (start = '0') then
		      BANK <= "00110";
            isRamOverlaySelected <= '1';
            if pa(2 downto 0) = "111" then
                start <= '1';
            end if;
        elsif (CS314n = '0') then
            if register_314(1) = '0' then  -- Activate RAM overlay
				    BANK <= "00111";
                isRamOverlaySelected <= '0';
            else
				    BANK <= "00101";
                isRamOverlaySelected <= '1';
            end if;
        else
            case pa(2 downto 0) is
                when "111" =>
					     BANK <= "--110";
                when "110" =>
					     BANK <= "--101";
                when "101" =>
					     BANK <= "--100";
                when "100" =>
					     BANK <= "--011";
                when "011" =>
						  BANK <= "--010";
                when "010" =>
					     BANK <= "--001";
                when "001" =>
					     BANK <= "--000";
                when others =>
					     BANK <= "--111";
                    isRamOverlaySelected <= '0';
            end case;

            if twilighte_register(4) = '1' then  -- Telestrat emulation
                isRamOverlaySelected <= '0';
            else
                isRamOverlaySelected <= '1';
            end if;

            if ((pa(2 downto 0) = "100") or (pa(2 downto 0) = "011") or (pa(2 downto 0) = "010") or (pa(2 downto 0) = "001")) then
					 BANK(3) <= twilighte_banking_register(0);
					 BANK(4) <= twilighte_banking_register(1);
                if (twilighte_banking_register(2) = '1') then
                    case pa(2 downto 0) is
                        when "100" =>
								    BANK <= "--111";
                        when "011" =>
								    BANK <= "--110";
                        when "010" =>
								    BANK <= "--101";
                        when "001" =>
								    BANK <= "--100";
                        when others => null;
                    end case;
                end if;
                isRamOverlaySelected <= not twilighte_register(5);
            else
				    BANK <= "00---";
            end if;
        end if;
    end if;
end process;


process (R_W,clk,nRESET )
begin
				if    CS342n = '0'  and R_W = '1' then
							 DB_OUT <= twilighte_register;
				elsif CS343n = '0'  and R_W = '1' then
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
				register_314 <= "00000000";
				nmiFromTwilighteBoard <='0';
		elsif falling_edge(CLK) then
				if CS342n = '0'  and R_W = '0' then
						twilighte_register <= DB_IN; -- EEPROM register
				elsif CS343n = '0'  and R_W = '0' then
						twilighte_banking_register <= DB_IN;
				elsif cs314n = '0'  and R_W = '0' then
						register_314 <= DB_IN ;
						DB_OUT <= "ZZZZZZZZ";
				end if;

	  end if;
 end process;	

end EXTENSION;