#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export LANG=C

# ===== Parâmetros =====
CNF_DIR="${1:-../Benchmarks/2024}"     # diretório raiz com .cnf (nível 1)
SUBSET_N="${SUBSET_N:-400}"
SEED="${SEED:-42}"
JOBS="${JOBS:-9}"
TIME_LIMIT="${TIME_LIMIT:-5000}"
REUSE_SUBSET="${REUSE_SUBSET:-1}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts_root="$(cd "$here/.." && pwd)"

if [ -x "$here/run-batch-mab.sh" ]; then
  batch_runner="$here/run-batch-mab.sh"
elif [ -x "$scripts_root/run-batch-mab.sh" ]; then
  batch_runner="$scripts_root/run-batch-mab.sh"
else
  echo "[grid] run-batch-mab.sh não encontrado próximo a $here" >&2
  exit 1
fi

# ===== Normaliza para ABSOLUTO =====
CNF_DIR_ABS="$(cd "$CNF_DIR" && pwd)"
SUBSETS_ROOT="${SUBSETS_ROOT:-$CNF_DIR_ABS/subsets}"

# ===== Estagnação "Ballock-style" + Telemetria + Seed =====
STAG_ARGS=(--stagnation=1 --stag-ema=1 --stag-alpha=0.2 --stag-pc=200 --stag-pl=2000 --stag-eps=0.1)
TEL_ARGS=(--exp-telemetry=1)
SEED_ARG=(--seed="$SEED")

# ===== Malha enxuta (6 configs) =====
GRID=(
  "mab-c1414-e0-h5000   --mab-mode=1 --mab-ucb-c=1.414 --mab-eps=0  --mab-horizon=5000"
  "mab-c1000-e0-h5000   --mab-mode=1 --mab-ucb-c=1.000 --mab-eps=0  --mab-horizon=5000"
  "mab-c2000-e0-h5000   --mab-mode=1 --mab-ucb-c=2.000 --mab-eps=0  --mab-horizon=5000"
  "mab-c1414-e25-h5000  --mab-mode=1 --mab-ucb-c=1.414 --mab-eps=25 --mab-horizon=5000"
  "mab-c1414-e0-h2000   --mab-mode=1 --mab-ucb-c=1.414 --mab-eps=0  --mab-horizon=2000"
  "baseline-stag        --mab-mode=0"
)

# ===== Checks =====
[ -d "$CNF_DIR_ABS" ] || { echo "CNF_DIR inexistente: $CNF_DIR_ABS" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 é necessário." >&2; exit 1; }

# ===== Gera/Reusa subset determinístico (agora com hardlinks/cópias) =====
SUBSET_DIR="$SUBSETS_ROOT/seed-$SEED-N$SUBSET_N"
mkdir -p "$SUBSET_DIR"

has_subset() {
  find "$SUBSET_DIR" -maxdepth 1 -type f -name '*.cnf' -print -quit | grep -q .
}

if [ "$REUSE_SUBSET" = "1" ] && has_subset ; then
  N_SUBSET=$(find "$SUBSET_DIR" -maxdepth 1 -type f -name '*.cnf' | wc -l)
  echo "[grid] Reusando subset existente: $SUBSET_DIR (|CNF|=$N_SUBSET)"
else
  echo "[grid] (Re)criando subset em: $SUBSET_DIR"
  LIST0="$(mktemp)"
  # Lista ABSOLUTA (evita links quebrados)
  find "$CNF_DIR_ABS" -maxdepth 1 -type f -name '*.cnf' -print0 > "$LIST0"
  if [ ! -s "$LIST0" ]; then
    echo "Nenhum .cnf em $CNF_DIR_ABS" >&2
    rm -f "$LIST0"; exit 1
  fi

  TMP_LIST="$(mktemp)"
  python3 - "$LIST0" "$SUBSET_N" "$SEED" > "$TMP_LIST" <<'PY'
import sys, os, random
list_path = sys.argv[1]; N=int(sys.argv[2]); SEED=int(sys.argv[3])
with open(list_path, 'rb') as f:
    files = [x for x in f.read().split(b'\0') if x]
files = [os.fsdecode(p) for p in files]
files.sort()
random.seed(SEED)
chosen = files if len(files) <= N else random.sample(files, N)
for p in chosen:
    print(p)
PY

  # Limpa subset antigo e cria hardlinks (fallback cp)
  find "$SUBSET_DIR" -maxdepth 1 -type f -name '*.cnf' -exec rm -f {} +
  while IFS= read -r abs; do
    [ -n "$abs" ] || continue
    base="$(basename "$abs")"
    # tenta hardlink (mesmo FS); se falhar, copia
    if ! ln -f "$abs" "$SUBSET_DIR/$base" 2>/dev/null; then
      cp -f "$abs" "$SUBSET_DIR/$base"
    fi
  done < "$TMP_LIST"

  rm -f "$LIST0" "$TMP_LIST"
  N_SUBSET=$(find "$SUBSET_DIR" -maxdepth 1 -type f -name '*.cnf' | wc -l)
  echo "[grid] subset pronto: $SUBSET_DIR (|CNF|=$N_SUBSET)"
fi

# ===== Roda a malha =====
for entry in "${GRID[@]}"; do
  label="${entry%%[[:space:]]*}"
  args="${entry#*[[:space:]]}"
  echo; echo ">>> Rodando grade: $label"

  # Continue even if some instances fail/timeout in this batch
  if "$batch_runner" \
    --log-suffix "$label-seed$SEED" \
    --jobs "$JOBS" \
    --time-limit "$TIME_LIMIT" \
    "$SUBSET_DIR" \
    -- "${TEL_ARGS[@]}" "${STAG_ARGS[@]}" ${args} "${SEED_ARG[@]}"
  then
    echo "[grid] $label concluído com sucesso"
  else
    echo "[grid] AVISO: $label teve falhas/timeouts, mas continuando próxima grade..." >&2
  fi
done

echo; echo "[grid] Concluído. Logs em: $SUBSET_DIR/logs-<suffix>/"
