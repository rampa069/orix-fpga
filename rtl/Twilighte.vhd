library ieee;
use ieee.std_logic_1164.all;

entity Twilighte is
    port (
        CLK              : in  std_logic;
        R_W              : in  std_logic;
        nRESET           : in  std_logic;
        nMAP             : in  std_logic;
        CS314n           : in  std_logic;   -- VIA
        CS340n           : in  std_logic;   -- CH376 activation
        CS342n           : in  std_logic;   -- Twilighte register
        CS343n           : in  std_logic;   -- Twilighte Banking
        PA               : in  std_logic_vector(7 downto 0);
        DB_IN            : in  std_logic_vector(7 downto 0);
        DB_OUT           : out std_logic_vector(7 downto 0);
        BANK             : out std_logic_vector(4 downto 0);
        ISRAM            : out std_logic
    );
end Twilighte;

architecture Behavioral of Twilighte is
    signal start                  : std_logic := '0';
    signal isRamOverlaySelected   : std_logic := '1';
    signal register_314           : std_logic_vector(7 downto 0) := (others => '0');
    signal twilighte_register     : std_logic_vector(7 downto 0) := "10000011";
    signal twilighte_banking_register : std_logic_vector(7 downto 0) := (others => '0');
begin
    ISRAM <= '1' when isRamOverlaySelected = '0' else '0';

    -- BANK Control Process
    process (nRESET, PA, start, CS314n, twilighte_register, twilighte_banking_register)
    begin
        if nRESET = '0' then
            BANK <= "00110";
            start <= '0';
            isRamOverlaySelected <= '1';
        else
            if start = '0' then
                BANK <= "00110";
                isRamOverlaySelected <= '1';
                if PA(2 downto 0) = "111" then
                    start <= '1';
                end if;
            elsif CS314n = '0' then
                if register_314(1) = '0' then
                    BANK <= "00111";
                    isRamOverlaySelected <= '0';
                else
                    BANK <= "00101";
                    isRamOverlaySelected <= '1';
                end if;
            else
                case PA(2 downto 0) is
                    when "111" => BANK(2 downto 0) <= "110";
                    when "110" => BANK(2 downto 0) <= "101";
                    when "101" => BANK(2 downto 0) <= "100";
                    when "100" => BANK(2 downto 0) <= "011";
                    when "011" => BANK(2 downto 0) <= "010";
                    when "010" => BANK(2 downto 0) <= "001";
                    when "001" => BANK(2 downto 0) <= "000";
                    when others => BANK(2 downto 0) <= "111";
                end case;

                -- Telestrat emulation and bank switching logic
                if twilighte_register(4) = '1' then
                    isRamOverlaySelected <= '0';
                else
                    isRamOverlaySelected <= '1';
                end if;

                if PA(2 downto 0) = "100" or PA(2 downto 0) = "011" or PA(2 downto 0) = "010" or PA(2 downto 0) = "001" then
                    BANK(3) <= twilighte_banking_register(0);
                    BANK(4) <= twilighte_banking_register(1);
                    if twilighte_banking_register(2) = '1' then
                        case PA(2 downto 0) is
                            when "100" => BANK(2 downto 0) <= "111";
                            when "011" => BANK(2 downto 0) <= "110";
                            when "010" => BANK(2 downto 0) <= "101";
                            when "001" => BANK(2 downto 0) <= "100";
                            when others => null;
                        end case;
                    end if;
                    isRamOverlaySelected <= not twilighte_register(5);
                else
                    BANK(4 downto 3) <= "00";
                end if;
            end if;
        end if;
    end process;

    -- Output DB_OUT based on CS and R_W
    process (CLK)
    begin
        if rising_edge(CLK) then
            if CS342n = '0' and R_W = '1' then
                DB_OUT <= twilighte_register;
            elsif CS343n = '0' and R_W = '1' then
                DB_OUT <= twilighte_banking_register;
            else
                DB_OUT <= "ZZZZZZZZ";
            end if;
        end if;
    end process;

    -- Register Update Process
    process (CLK)
    begin
        if rising_edge(CLK) then
            if nRESET = '0' then
                twilighte_register <= "10000011";
                twilighte_banking_register <= (others => '0');
                register_314 <= (others => '0');
            else
                if CS342n = '0' and R_W = '0' then
                    twilighte_register <= DB_IN;
                elsif CS343n = '0' and R_W = '0' then
                    twilighte_banking_register <= DB_IN;
                elsif CS314n = '0' and R_W = '0' then
                    register_314 <= DB_IN;
                end if;
            end if;
        end if;
    end process;
end Behavioral;
