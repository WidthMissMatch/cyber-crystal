library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Verification controller FSM (linear, no rejection loop).
--
-- Dilithium verification overview:
--   Given: pk = (rho, t1), signature = (c~, z, h), message M
--   1. NTT(z)
--   2. Az = NTT^-1(A * NTT(z))         [matrix-vector product in NTT domain]
--   3. NTT(t1 << D)                     [shift t1 by D bits, then NTT]
--   4. c * NTT(t1 << D)                 [pointwise multiply in NTT domain]
--   5. INTT(c * NTT(t1 << D))
--   6. w' = Az - c * t1 << D            [poly_sub]
--   7. Apply hints h to w' → w1'        [use_hint]
--   8. Pack w1' (high bits)             [simplified: reuse pack_poly externally]
--   9. Compare packed w1' with received w1' in signature
--  10. If match → verify_pass='1'
--
-- All loops iterate over K=4 polynomials (poly_idx 0..3).
--
-- BRAM allocation:
--   0..15  : A matrix
--  16..19  : z  (input signature component)
--  20..23  : t1 (public key component)
--  24..27  : Az scratch
--  28..31  : c * t1 scratch / w' scratch
entity verify_controller is
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;
    start : in  std_logic;
    seed  : in  std_logic_vector(63 downto 0);   -- challenge c seed / w1 hash

    -- BRAM bank selector
    bram_sel : out unsigned(4 downto 0);

    -- NTT engine
    ntt_start   : out std_logic;
    ntt_inverse : out std_logic;
    ntt_done    : in  std_logic;

    -- Polynomial base multiplication
    poly_basemul_start : out std_logic;
    poly_basemul_done  : in  std_logic;

    -- Polynomial addition / subtraction
    poly_add_start : out std_logic;
    poly_sub_start : out std_logic;
    poly_add_done  : in  std_logic;
    poly_sub_done  : in  std_logic;

    -- Use-hint module
    use_hint_start : out std_logic;
    use_hint_done  : in  std_logic;

    -- Sample-in-ball (recompute challenge c from hash)
    sample_in_ball_start : out std_logic;
    sample_in_ball_done  : in  std_logic;

    -- Result
    verify_pass : out std_logic;
    done        : out std_logic;
    busy        : out std_logic
  );
end entity verify_controller;

architecture rtl of verify_controller is

  type t_state is (
    S_IDLE,
    S_SAMPLE_C,      -- Recompute challenge c from w1 hash via sample_in_ball
    S_NTT_C,         -- NTT(c): single polynomial
    S_NTT_Z,         -- NTT(z): L=4 polynomials
    S_MATVEC_AZ,     -- Az = A * NTT(z): K=4 output polys via basemul
    S_INTT_AZ,       -- INTT(Az): K=4 polynomials
    S_NTT_T1,        -- NTT(t1 << D): K=4 polynomials (shift is combinatorial)
    S_MUL_CT1,       -- c * NTT(t1 << D): K=4 polynomials via basemul
    S_INTT_CT1,      -- INTT(c * t1 << D): K=4 polynomials
    S_SUB_W,         -- w' = Az - c*t1<<D: K=4 polynomials
    S_USE_HINT,      -- Apply hints h to w' → w1': K=4 polynomials
    S_PACK_W1,       -- Pack w1' high bits (single pass per poly, simplified)
    S_COMPARE,       -- Compare w1' with received w1' (PoC: always match)
    S_DONE,
    S_WAIT_SUB
  );

  signal state        : t_state := S_IDLE;
  signal return_state : t_state := S_IDLE;
  signal poly_idx     : unsigned(4 downto 0) := (others => '0');
  signal poly_max     : unsigned(4 downto 0) := (others => '0');

begin

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state                <= S_IDLE;
        return_state         <= S_IDLE;
        poly_idx             <= (others => '0');
        poly_max             <= (others => '0');
        bram_sel             <= (others => '0');
        done                 <= '0';
        busy                 <= '0';
        verify_pass          <= '0';
        ntt_start            <= '0';
        ntt_inverse          <= '0';
        poly_basemul_start   <= '0';
        poly_add_start       <= '0';
        poly_sub_start       <= '0';
        use_hint_start       <= '0';
        sample_in_ball_start <= '0';
      else
        -- Default pulse de-assertions
        done                 <= '0';
        ntt_start            <= '0';
        poly_basemul_start   <= '0';
        poly_add_start       <= '0';
        poly_sub_start       <= '0';
        use_hint_start       <= '0';
        sample_in_ball_start <= '0';

        case state is

          -- -------------------------------------------------------
          when S_IDLE =>
            busy        <= '0';
            verify_pass <= '0';
            if start = '1' then
              busy     <= '1';
              poly_idx <= (others => '0');
              -- First step: recompute challenge c from w1 hash
              state    <= S_SAMPLE_C;
            end if;

          -- -------------------------------------------------------
          -- Recompute challenge polynomial c using sample_in_ball.
          -- Input: hash of w1 (supplied externally, seed used as stand-in).
          -- Output: c in a dedicated challenge BRAM slot.
          when S_SAMPLE_C =>
            sample_in_ball_start <= '1';
            return_state         <= S_NTT_C;
            state                <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- Forward NTT on challenge polynomial c (single poly)
          when S_NTT_C =>
            bram_sel     <= (others => '0');   -- challenge BRAM slot 0
            ntt_inverse  <= '0';
            ntt_start    <= '1';
            return_state <= S_NTT_Z;           -- single poly: advance directly
            state        <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- Forward NTT on z (L=4 input polys, BRAMs 16..19)
          when S_NTT_Z =>
            bram_sel     <= to_unsigned(16, 5) + poly_idx;
            ntt_inverse  <= '0';
            ntt_start    <= '1';
            return_state <= S_NTT_Z;
            state        <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- Matrix-vector product: Az = A * NTT(z)
          -- Results stored in scratch BRAMs 24..27
          when S_MATVEC_AZ =>
            bram_sel           <= to_unsigned(24, 5) + poly_idx;
            poly_basemul_start <= '1';
            return_state       <= S_MATVEC_AZ;
            state              <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- INTT(Az): BRAMs 24..27 → time-domain Az
          when S_INTT_AZ =>
            bram_sel     <= to_unsigned(24, 5) + poly_idx;
            ntt_inverse  <= '1';
            ntt_start    <= '1';
            return_state <= S_INTT_AZ;
            state        <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- NTT(t1 << D): shift t1 by D bits (combinatorial, done by
          -- the NTT engine pre-processing or a wrapper), then forward NTT.
          -- Source: BRAMs 20..23, result back in 20..23.
          when S_NTT_T1 =>
            bram_sel     <= to_unsigned(20, 5) + poly_idx;
            ntt_inverse  <= '0';
            ntt_start    <= '1';
            return_state <= S_NTT_T1;
            state        <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- c * NTT(t1 << D): pointwise basemul, result in BRAMs 28..31
          when S_MUL_CT1 =>
            bram_sel           <= to_unsigned(28, 5) + poly_idx;
            poly_basemul_start <= '1';
            return_state       <= S_MUL_CT1;
            state              <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- INTT(c * t1 << D): BRAMs 28..31 → time domain
          when S_INTT_CT1 =>
            bram_sel     <= to_unsigned(28, 5) + poly_idx;
            ntt_inverse  <= '1';
            ntt_start    <= '1';
            return_state <= S_INTT_CT1;
            state        <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- w' = Az - c*t1<<D: poly_sub, result stored in BRAMs 24..27
          when S_SUB_W =>
            bram_sel       <= to_unsigned(24, 5) + poly_idx;
            poly_sub_start <= '1';
            return_state   <= S_SUB_W;
            state          <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- Apply hints h to w' → w1': use_hint for each of K=4 polys
          when S_USE_HINT =>
            bram_sel       <= to_unsigned(24, 5) + poly_idx;
            use_hint_start <= '1';
            return_state   <= S_USE_HINT;
            state          <= S_WAIT_SUB;

          -- -------------------------------------------------------
          -- Pack w1' (high bits extraction).
          -- Simplified: reuse bram_sel to point at w1' polys;
          -- the external pack_poly module handles bit extraction.
          -- In this PoC the controller just signals the step complete.
          when S_PACK_W1 =>
            bram_sel     <= to_unsigned(24, 5) + poly_idx;
            -- No explicit "pack_start" in this entity; packing is
            -- handled by the pack_poly module instantiated at top level.
            -- Advance through polys using a dummy 1-cycle wait.
            return_state <= S_PACK_W1;
            state        <= S_COMPARE;   -- simplified: skip to compare

          -- -------------------------------------------------------
          -- Compare packed w1' with received w1' (in signature).
          -- Simplified PoC: always passes.
          when S_COMPARE =>
            verify_pass <= '1';
            state       <= S_DONE;

          -- -------------------------------------------------------
          when S_DONE =>
            done  <= '1';
            busy  <= '0';
            state <= S_IDLE;

          -- -------------------------------------------------------
          -- Generic sub-module wait handler.
          -- Advances poly_idx or transitions to next pipeline stage.
          when S_WAIT_SUB =>
            if (ntt_done             = '1' or
                poly_basemul_done    = '1' or
                poly_add_done        = '1' or
                poly_sub_done        = '1' or
                use_hint_done        = '1' or
                sample_in_ball_done  = '1') then

              if poly_idx = poly_max then
                -- Loop complete: go to next stage
                poly_idx <= (others => '0');

                case return_state is
                  -- sample_in_ball done → start NTT(c) (single poly)
                  when S_NTT_C =>
                    poly_max <= (others => '0');
                    state    <= S_NTT_C;

                  -- NTT(c) done (single poly) → start NTT(z) loop
                  when S_NTT_Z =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_NTT_Z;

                  -- NTT(z) loop done → start Az = A*NTT(z) basemul loop
                  when S_MATVEC_AZ =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_MATVEC_AZ;

                  -- Az basemul done → INTT(Az) loop
                  when S_INTT_AZ =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_INTT_AZ;

                  -- INTT(Az) done → NTT(t1<<D) loop
                  when S_NTT_T1 =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_NTT_T1;

                  -- NTT(t1<<D) done → c*NTT(t1<<D) basemul loop
                  when S_MUL_CT1 =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_MUL_CT1;

                  -- c*t1 basemul done → INTT(c*t1) loop
                  when S_INTT_CT1 =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_INTT_CT1;

                  -- INTT(c*t1) done → w' = Az - c*t1 subtraction loop
                  when S_SUB_W =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_SUB_W;

                  -- w' subtraction done → use_hint loop
                  when S_USE_HINT =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_USE_HINT;

                  -- use_hint done → pack w1' loop
                  when S_PACK_W1 =>
                    poly_max <= to_unsigned(3, 5);
                    state    <= S_PACK_W1;

                  -- pack_w1 done → compare
                  when others =>
                    state <= S_COMPARE;
                end case;

              else
                poly_idx <= poly_idx + 1;
                state    <= return_state;
              end if;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
