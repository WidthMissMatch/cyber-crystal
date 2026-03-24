library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Poly-level low_bits: reads 256 coefficients from src BRAM,
-- outputs a0 (low part of decompose) to dst BRAM.
-- a0 is centred signed; stored as unsigned mod-q:
--   if a0 < 0: output = q + a0   (wraps into upper range [q-GAMMA2, q-1])
--   if a0 >= 0: output = a0      (lower range [0, GAMMA2])

entity low_bits is
  port (
    clk      : in  std_logic;
    rst      : in  std_logic;
    start    : in  std_logic;
    src_addr : out unsigned(7 downto 0);
    src_data : in  unsigned(22 downto 0);
    dst_we   : out std_logic;
    dst_addr : out unsigned(7 downto 0);
    dst_data : out unsigned(22 downto 0);
    done     : out std_logic;
    busy     : out std_logic
  );
end entity low_bits;

architecture rtl of low_bits is

  type t_state is (S_IDLE, S_READ, S_WAIT, S_FEED, S_WRITE, S_DONE);
  signal state : t_state := S_IDLE;
  signal idx   : unsigned(7 downto 0) := (others => '0');

  -- Decompose component signals
  signal dec_a_in      : unsigned(22 downto 0) := (others => '0');
  signal dec_valid_in  : std_logic := '0';
  signal dec_a1_out    : unsigned(5 downto 0);
  signal dec_a0_out    : signed(18 downto 0);
  signal dec_valid_out : std_logic;

  -- Capture write address in pipeline
  signal write_addr_r  : unsigned(7 downto 0) := (others => '0');

begin

  -- Instantiate the decompose pipeline
  u_dec : entity work.decompose
    port map (
      clk       => clk,
      rst       => rst,
      a_in      => dec_a_in,
      valid_in  => dec_valid_in,
      a1_out    => dec_a1_out,
      a0_out    => dec_a0_out,
      valid_out => dec_valid_out
    );

  process(clk)
    variable a0_int : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state         <= S_IDLE;
        done          <= '0';
        busy          <= '0';
        dst_we        <= '0';
        dec_valid_in  <= '0';
        idx           <= (others => '0');
        write_addr_r  <= (others => '0');
      else
        done         <= '0';
        dst_we       <= '0';
        dec_valid_in <= '0';

        case state is

          when S_IDLE =>
            busy <= '0';
            if start = '1' then
              idx   <= (others => '0');
              busy  <= '1';
              state <= S_READ;
            end if;

          when S_READ =>
            src_addr <= idx;
            state    <= S_WAIT;

          when S_WAIT =>
            state <= S_FEED;

          when S_FEED =>
            dec_a_in      <= src_data;
            dec_valid_in  <= '1';
            write_addr_r  <= idx;
            state         <= S_WRITE;

          when S_WRITE =>
            -- Convert centred a0 to unsigned mod-q representation
            a0_int := to_integer(dec_a0_out);
            if a0_int < 0 then
              dst_data <= to_unsigned(DIL_Q + a0_int, 23);
            else
              dst_data <= to_unsigned(a0_int, 23);
            end if;
            dst_addr <= write_addr_r;
            dst_we   <= '1';

            if write_addr_r = to_unsigned(255, 8) then
              state <= S_DONE;
            else
              idx   <= write_addr_r + 1;
              state <= S_READ;
            end if;

          when S_DONE =>
            done  <= '1';
            busy  <= '0';
            state <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
