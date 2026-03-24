library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Sequential polynomial packing.
-- Reads all 256 coefficients from BRAM (1-cycle latency) and streams them
-- out one per cycle as a 23-bit value with coeff_valid='1'.
entity pack_poly is
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;
    start       : in  std_logic;
    -- BRAM read port
    bram_addr   : out unsigned(7 downto 0);
    bram_data   : in  unsigned(22 downto 0);
    -- Output stream
    coeff_out   : out unsigned(22 downto 0);
    coeff_valid : out std_logic;
    done        : out std_logic;
    busy        : out std_logic
  );
end entity pack_poly;

architecture rtl of pack_poly is

  type t_state is (S_IDLE, S_READ, S_WAIT, S_OUTPUT, S_DONE);
  signal state : t_state := S_IDLE;
  signal idx   : unsigned(7 downto 0) := (others => '0');

begin

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state       <= S_IDLE;
        done        <= '0';
        busy        <= '0';
        coeff_valid <= '0';
        coeff_out   <= (others => '0');
        bram_addr   <= (others => '0');
        idx         <= (others => '0');
      else
        -- Default de-assertions each cycle
        done        <= '0';
        coeff_valid <= '0';

        case state is

          -- -------------------------------------------------------
          when S_IDLE =>
            busy <= '0';
            if start = '1' then
              idx   <= (others => '0');
              busy  <= '1';
              state <= S_READ;
            end if;

          -- -------------------------------------------------------
          -- Issue address to BRAM
          when S_READ =>
            bram_addr <= idx;
            state     <= S_WAIT;

          -- -------------------------------------------------------
          -- One-cycle BRAM read latency
          when S_WAIT =>
            state <= S_OUTPUT;

          -- -------------------------------------------------------
          -- Data from BRAM is now valid; emit coefficient
          when S_OUTPUT =>
            coeff_out   <= bram_data;
            coeff_valid <= '1';

            if idx = to_unsigned(255, 8) then
              state <= S_DONE;
            else
              idx   <= idx + 1;
              state <= S_READ;
            end if;

          -- -------------------------------------------------------
          when S_DONE =>
            done  <= '1';
            busy  <= '0';
            state <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
