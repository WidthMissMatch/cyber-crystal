library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Generates the challenge polynomial c with exactly TAU=39 nonzero coefficients
-- in {-1, +1} (represented as {1, q-1} mod q) via a Fisher-Yates partial shuffle.
-- Algorithm matches poly_challenge() in the Dilithium reference implementation,
-- using the internal LFSR instead of SHAKE-256.
--
-- Steps:
--   1. Zero internal 256-entry array.
--   2. Collect 8 sign bytes from LFSR → 64 sign bits.
--   3. For i = (DIL_N - DIL_TAU) to (DIL_N - 1)  [i.e. 217..255]:
--        get random byte b; if b > i, reject and retry.
--        c[i] = c[b]
--        c[b] = 1  if sign_bit[(i - (DIL_N - DIL_TAU))] = '0'
--               q-1 if sign_bit[(i - (DIL_N - DIL_TAU))] = '1'
--   4. Flush internal array to output BRAM (256 writes).
entity sample_in_ball is
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;
    start : in  std_logic;
    seed  : in  std_logic_vector(63 downto 0);
    we_a  : out std_logic;
    addr_a: out unsigned(7 downto 0);
    din_a : out unsigned(22 downto 0);
    done  : out std_logic;
    busy  : out std_logic
  );
end entity sample_in_ball;

architecture rtl of sample_in_ball is

  -- Internal array for Fisher-Yates shuffle
  type t_ball_arr is array(0 to 255) of unsigned(22 downto 0);
  signal c_arr : t_ball_arr := (others => (others => '0'));

  -- LFSR interface
  signal lfsr_load    : std_logic := '0';
  signal lfsr_enable  : std_logic := '0';
  signal lfsr_rnd_out : std_logic_vector(7 downto 0);
  signal lfsr_valid   : std_logic;

  -- Sign bits (64 bits, one per nonzero coefficient)
  signal sign_bits    : std_logic_vector(63 downto 0) := (others => '0');

  -- FSM
  type t_state is (
    S_IDLE,
    S_SEED,
    S_INIT,         -- zero c_arr, 256 cycles
    S_GET_SIGNS,    -- collect 8 bytes → 64 sign bits
    S_SIGN_WAIT,    -- 1-cycle LFSR pipeline latency per sign byte
    S_SHUFFLE_REQ,  -- request random byte b for current i
    S_SHUFFLE_WAIT, -- wait for LFSR valid
    S_SHUFFLE_CHK,  -- check b <= i; if not, retry
    S_SHUFFLE_DO,   -- perform swap: c[i]=c[b], c[b]=sign value
    S_FLUSH,        -- write c_arr to output BRAM
    S_DONE
  );
  signal state : t_state := S_IDLE;

  -- Loop counters
  signal init_idx   : unsigned(7 downto 0) := (others => '0'); -- 0..255 for S_INIT / S_FLUSH
  signal sign_cnt   : unsigned(2 downto 0) := (others => '0'); -- 0..7 for 8 sign bytes
  signal shuf_i     : unsigned(7 downto 0) := (others => '0'); -- 217..255
  signal sign_pos   : unsigned(5 downto 0) := (others => '0'); -- 0..38 (index into sign_bits)

  -- Shuffle temporaries
  signal b_byte     : unsigned(7 downto 0) := (others => '0');
  signal ci_val     : unsigned(22 downto 0) := (others => '0'); -- saved c[i]

  -- Constants
  constant C_SHUF_START : unsigned(7 downto 0) :=
    to_unsigned(DIL_N - DIL_TAU, 8);   -- 217

begin

  -- Instantiate LFSR PRNG
  u_lfsr : entity work.lfsr_prng
    port map (
      clk     => clk,
      rst     => rst,
      seed    => seed,
      load    => lfsr_load,
      enable  => lfsr_enable,
      rnd_out => lfsr_rnd_out,
      valid   => lfsr_valid
    );

  process(clk)
    variable v_sign : std_logic;
    variable v_bi   : integer range 0 to 255;
    variable v_ii   : integer range 0 to 255;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state       <= S_IDLE;
        lfsr_load   <= '0';
        lfsr_enable <= '0';
        we_a        <= '0';
        addr_a      <= (others => '0');
        din_a       <= (others => '0');
        done        <= '0';
        busy        <= '0';
        init_idx    <= (others => '0');
        sign_cnt    <= (others => '0');
        shuf_i      <= (others => '0');
        sign_pos    <= (others => '0');
        b_byte      <= (others => '0');
        ci_val      <= (others => '0');
        sign_bits   <= (others => '0');
        c_arr       <= (others => (others => '0'));
      else
        -- Default deasserts
        lfsr_load   <= '0';
        lfsr_enable <= '0';
        we_a        <= '0';
        done        <= '0';

        case state is

          -- ---------------------------------------------------------------
          when S_IDLE =>
            busy <= '0';
            if start = '1' then
              busy     <= '1';
              init_idx <= (others => '0');
              state    <= S_SEED;
            end if;

          -- ---------------------------------------------------------------
          -- Load seed into LFSR
          when S_SEED =>
            lfsr_load <= '1';
            init_idx  <= (others => '0');
            state     <= S_INIT;

          -- ---------------------------------------------------------------
          -- Zero internal array (256 cycles)
          when S_INIT =>
            c_arr(to_integer(init_idx)) <= (others => '0');
            if init_idx = to_unsigned(DIL_N - 1, 8) then
              sign_cnt <= (others => '0');
              state    <= S_GET_SIGNS;
            else
              init_idx <= init_idx + 1;
            end if;

          -- ---------------------------------------------------------------
          -- Collect 8 bytes → 64 sign bits (8 iterations)
          -- Each iteration: enable LFSR this cycle, wait 1 cycle for valid
          when S_GET_SIGNS =>
            lfsr_enable <= '1';
            state       <= S_SIGN_WAIT;

          when S_SIGN_WAIT =>
            if lfsr_valid = '1' then
              -- Pack byte into sign_bits at position sign_cnt*8
              -- sign_bits[63:56]=byte7, ..., sign_bits[7:0]=byte0
              -- We fill from MSB so sign_bit index 0 = sign_bits[63]
              case to_integer(sign_cnt) is
                when 0 => sign_bits(63 downto 56) <= lfsr_rnd_out;
                when 1 => sign_bits(55 downto 48) <= lfsr_rnd_out;
                when 2 => sign_bits(47 downto 40) <= lfsr_rnd_out;
                when 3 => sign_bits(39 downto 32) <= lfsr_rnd_out;
                when 4 => sign_bits(31 downto 24) <= lfsr_rnd_out;
                when 5 => sign_bits(23 downto 16) <= lfsr_rnd_out;
                when 6 => sign_bits(15 downto 8)  <= lfsr_rnd_out;
                when 7 => sign_bits(7  downto 0)  <= lfsr_rnd_out;
                when others => null;
              end case;

              if sign_cnt = "111" then
                -- All 8 sign bytes collected; start shuffle
                shuf_i   <= C_SHUF_START;  -- i = 217
                sign_pos <= (others => '0');
                state    <= S_SHUFFLE_REQ;
              else
                sign_cnt <= sign_cnt + 1;
                state    <= S_GET_SIGNS;
              end if;
            end if;
            -- If lfsr_valid not yet asserted, stay and wait (should not normally occur)

          -- ---------------------------------------------------------------
          -- Fisher-Yates shuffle: request random byte for current i
          when S_SHUFFLE_REQ =>
            lfsr_enable <= '1';
            state       <= S_SHUFFLE_WAIT;

          -- Wait for LFSR to produce the byte
          when S_SHUFFLE_WAIT =>
            if lfsr_valid = '1' then
              b_byte <= unsigned(lfsr_rnd_out);
              state  <= S_SHUFFLE_CHK;
            end if;

          -- Check b <= i (rejection step)
          when S_SHUFFLE_CHK =>
            if b_byte > shuf_i then
              -- Reject: try another byte for the same i
              state <= S_SHUFFLE_REQ;
            else
              -- Accept: save c[i] for swap
              ci_val <= c_arr(to_integer(shuf_i));
              state  <= S_SHUFFLE_DO;
            end if;

          -- Perform the swap and assign sign value
          when S_SHUFFLE_DO =>
            v_bi := to_integer(b_byte);
            v_ii := to_integer(shuf_i);

            -- c[i] = c[b]
            c_arr(v_ii) <= c_arr(v_bi);

            -- c[b] = sign ? q-1 : 1
            -- sign_bit index = sign_pos (0..38 as shuf_i advances 217..255)
            v_sign := sign_bits(63 - to_integer(sign_pos));
            if v_sign = '1' then
              c_arr(v_bi) <= to_unsigned(DIL_Q - 1, 23);  -- -1 mod q
            else
              c_arr(v_bi) <= to_unsigned(1, 23);
            end if;

            sign_pos <= sign_pos + 1;

            if shuf_i = to_unsigned(DIL_N - 1, 8) then
              -- All TAU positions filled; start flushing
              init_idx <= (others => '0');
              state    <= S_FLUSH;
            else
              shuf_i <= shuf_i + 1;
              state  <= S_SHUFFLE_REQ;
            end if;

          -- ---------------------------------------------------------------
          -- Write c_arr to output BRAM (256 cycles)
          when S_FLUSH =>
            we_a   <= '1';
            addr_a <= init_idx;
            din_a  <= c_arr(to_integer(init_idx));

            if init_idx = to_unsigned(DIL_N - 1, 8) then
              state <= S_DONE;
            else
              init_idx <= init_idx + 1;
            end if;

          -- ---------------------------------------------------------------
          when S_DONE =>
            we_a  <= '0';
            done  <= '1';
            busy  <= '0';
            state <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
