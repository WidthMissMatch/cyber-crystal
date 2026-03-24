library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Sequential polynomial unpacking.
-- Accepts a stream of 23-bit coefficients (coeff_valid handshake) and
-- writes them into BRAM at sequential addresses 0..255.
-- done pulses for 1 cycle after all 256 coefficients have been written.
entity unpack_poly is
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;
    start       : in  std_logic;
    -- Input coefficient stream
    coeff_in    : in  unsigned(22 downto 0);
    coeff_valid : in  std_logic;
    -- BRAM write port
    bram_we     : out std_logic;
    bram_addr   : out unsigned(7 downto 0);
    bram_data   : out unsigned(22 downto 0);
    done        : out std_logic;
    busy        : out std_logic
  );
end entity unpack_poly;

architecture rtl of unpack_poly is

  type t_state is (S_IDLE, S_RUNNING, S_DONE);
  signal state : t_state := S_IDLE;
  signal idx   : unsigned(7 downto 0) := (others => '0');

begin

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state     <= S_IDLE;
        done      <= '0';
        busy      <= '0';
        bram_we   <= '0';
        bram_addr <= (others => '0');
        bram_data <= (others => '0');
        idx       <= (others => '0');
      else
        -- Default de-assertions
        done    <= '0';
        bram_we <= '0';

        case state is

          -- -------------------------------------------------------
          when S_IDLE =>
            busy <= '0';
            if start = '1' then
              idx   <= (others => '0');
              busy  <= '1';
              state <= S_RUNNING;
            end if;

          -- -------------------------------------------------------
          -- Wait for incoming coefficients one at a time.
          when S_RUNNING =>
            if coeff_valid = '1' then
              bram_we   <= '1';
              bram_addr <= idx;
              bram_data <= coeff_in;

              if idx = to_unsigned(255, 8) then
                state <= S_DONE;
              else
                idx <= idx + 1;
              end if;
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
