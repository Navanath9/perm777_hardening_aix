#!/bin/ksh
###############################################################################
# perm_hardening_aix.ksh  v2.1.0
#
# Permission Hardening Suite for AIX  (ksh88 / ksh93 compatible)
#
# QUICK SYNTAX CHECK BEFORE FIRST RUN:
#   ksh -n /path/to/perm_hardening_aix.ksh
#   (returns silently with exit 0 if intact)
#
# DEPLOY:
#   chown root:system perm_hardening_aix.ksh
#   chmod 700 perm_hardening_aix.ksh
#   ksh perm_hardening_aix.ksh
#
# KSH88 COMPATIBILITY — enforced throughout:
#   NO typeset -a          (numbered vars + eval for all lists)
#   NO (( ternary ?: ))    (plain if/fi only in arithmetic)
#   NO ${var:n:len}        (awk for all substring ops)
#   NO $'...' strings
#   NO PIPESTATUS
#   NO print               (printf used everywhere)
#   NO forward references  (every fn defined before first call)
#   _SCAN_TOTAL set in SAME shell scope as while-read loop
#   ETA computed INLINE inside prog_bar — NO progress_eta fn
#   date called via $(date '+...') stored in var before use
#
# MODES:
#   Interactive menu  — Discovery, Remediation, Rollback,
#                       Verify, Reports, Settings, Diagnostics
#   Batch/cron        — --discover --remediate --rollback --verify
#
# SAFETY:
#   Read-only scan | Mandatory dry-run | YES confirmation gate
#   Symlinks never touched | Full pre-state capture (mode/owner/group/ACL)
#   Checkpoint + resume for large interrupted scans
###############################################################################
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin
export PATH
umask 077

###############################################################################
# SECTION 1 — GLOBAL DEFAULTS
###############################################################################
BASE_OUT="/mnt/nim_perm_hardening"
DEFAULT_ROOTS=""
DEFAULT_MODE="WW"
DEFAULT_CAND="AUTO"
RECENT_DAYS=90
LARGE_MB=100
HIGH_FILES=1000
EXCLUDE_TMP_ROOT=1
SKIP_ACL=0
CHUNK_SIZE=5000
PROG_INTERVAL=50
SKIP_REC=1
SKIP_DU=1
COUNT_MATCHED_DIRS=1    # 1=count files in matched dirs only (fast); 0=skip entirely
FIND_TIMEOUT=0
RESUME_ENABLED=1
MAX_TMP_MB=500
LOG_TIMING=1
CONF_FILE="${HOME:-/root}/.perm_hardening_aix.conf"
VERSION="2.1.0"
HOST=$(hostname 2>/dev/null)

###############################################################################
# SECTION 2 — ANSI COLOR
# Inline escape codes — no sub-helper functions, ksh88 safe
###############################################################################
USE_COLOR=0
if [[ -t 1 ]]; then
  case "${TERM:-}" in
    xterm*|vt100*|linux*|screen*|ansi*) USE_COLOR=1 ;;
  esac
fi

BOLD() {
  [[ $USE_COLOR -eq 1 ]] && printf "\033[1m"
  printf "%s" "$*"
  [[ $USE_COLOR -eq 1 ]] && printf "\033[0m"
  printf "\n"
}
RED() {
  [[ $USE_COLOR -eq 1 ]] && printf "\033[1;31m"
  printf "%s" "$*"
  [[ $USE_COLOR -eq 1 ]] && printf "\033[0m"
  printf "\n"
}
GREEN() {
  [[ $USE_COLOR -eq 1 ]] && printf "\033[1;32m"
  printf "%s" "$*"
  [[ $USE_COLOR -eq 1 ]] && printf "\033[0m"
  printf "\n"
}
YELLOW() {
  [[ $USE_COLOR -eq 1 ]] && printf "\033[1;33m"
  printf "%s" "$*"
  [[ $USE_COLOR -eq 1 ]] && printf "\033[0m"
  printf "\n"
}
CYAN() {
  [[ $USE_COLOR -eq 1 ]] && printf "\033[1;36m"
  printf "%s" "$*"
  [[ $USE_COLOR -eq 1 ]] && printf "\033[0m"
  printf "\n"
}

SEP="============================================================"
SEP2="------------------------------------------------------------"

###############################################################################
# SECTION 3 — LOGGING
###############################################################################
_LOGFILE=""

tlog() {
  # tlog: terminal + log file
  typeset _M
  _M="$(date '+%Y-%m-%d %H:%M:%S') [$HOST] $*"
  printf "%s\n" "$_M"
  [[ -n "$_LOGFILE" ]] && printf "%s\n" "$_M" >>"$_LOGFILE"
}

flog() {
  # flog: log file only
  [[ -n "$_LOGFILE" ]] || return
  printf "%s [%s] %s\n" \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$HOST" "$*" >>"$_LOGFILE"
}

tlog_timing() {
  # tlog_timing: log file only, gated by LOG_TIMING
  [[ $LOG_TIMING -eq 1 ]] && flog "TIMING: $*"
}

die()   { RED   "ERROR: $*"; exit 1; }
warn()  { YELLOW "WARN:  $*"; }
pause() { printf "\nPress ENTER to continue..."; read _PDUMMY; }

confirm() {
  # confirm <prompt>  — returns 0=yes 1=no
  printf "%s [y/N]: " "$1"
  read _CANS
  case "$_CANS" in y|Y) return 0 ;; *) return 1 ;; esac
}

confirm_yes() {
  # confirm_yes <label>  — requires literal "YES"
  printf "%s\nType YES to proceed: " "$1"
  read _CYES
  [[ "$_CYES" = "YES" ]]
}

is_int() {
  printf "%s" "$1" | awk '$0 ~ /^[0-9]+$/ { exit 0 } { exit 1 }'
}

###############################################################################
# SECTION 4 — INPUT HIGHLIGHT
# ask <varname> <prompt>
# Shows prompt, reads user input in bold/reverse-video, stores in varname.
###############################################################################
ask() {
  typeset _AV="$1" _AP="$2" _AI
  printf "%s" "$_AP"
  [[ $USE_COLOR -eq 1 ]] && printf "\033[1;7m"
  read _AI
  [[ $USE_COLOR -eq 1 ]] && printf "\033[0m"
  eval "${_AV}=\${_AI}"
}

###############################################################################
# SECTION 5 — PERSISTENT CONFIG
###############################################################################
load_conf() {
  [[ -r "$CONF_FILE" ]] || return 0
  while IFS='=' read _CK _CV; do
    case "$_CK" in
      '#'*|'') continue ;;
      BASE_OUT)         BASE_OUT="$_CV" ;;
      DEFAULT_ROOTS)    DEFAULT_ROOTS="$_CV" ;;
      DEFAULT_MODE)     DEFAULT_MODE="$_CV" ;;
      DEFAULT_CAND)     DEFAULT_CAND="$_CV" ;;
      RECENT_DAYS)      RECENT_DAYS="$_CV" ;;
      LARGE_MB)         LARGE_MB="$_CV" ;;
      HIGH_FILES)       HIGH_FILES="$_CV" ;;
      EXCLUDE_TMP_ROOT) EXCLUDE_TMP_ROOT="$_CV" ;;
      SKIP_ACL)         SKIP_ACL="$_CV" ;;
      CHUNK_SIZE)       CHUNK_SIZE="$_CV" ;;
      PROG_INTERVAL)    PROG_INTERVAL="$_CV" ;;
      SKIP_REC)         SKIP_REC="$_CV" ;;
      SKIP_DU)          SKIP_DU="$_CV" ;;
      COUNT_MATCHED_DIRS) COUNT_MATCHED_DIRS="$_CV" ;;
      FIND_TIMEOUT)     FIND_TIMEOUT="$_CV" ;;
      RESUME_ENABLED)   RESUME_ENABLED="$_CV" ;;
      MAX_TMP_MB)       MAX_TMP_MB="$_CV" ;;
      LOG_TIMING)       LOG_TIMING="$_CV" ;;
    esac
  done <"$CONF_FILE"
}

save_conf() {
  mkdir -p "$(dirname "$CONF_FILE")" 2>/dev/null
  typeset _NOW
  _NOW=$(date '+%Y-%m-%d %H:%M:%S')
  {
    printf "# perm_hardening_aix.ksh v%s — %s\n" "$VERSION" "$_NOW"
    printf "BASE_OUT=%s\n"         "$BASE_OUT"
    printf "DEFAULT_ROOTS=%s\n"    "$DEFAULT_ROOTS"
    printf "DEFAULT_MODE=%s\n"     "$DEFAULT_MODE"
    printf "DEFAULT_CAND=%s\n"     "$DEFAULT_CAND"
    printf "RECENT_DAYS=%s\n"      "$RECENT_DAYS"
    printf "LARGE_MB=%s\n"         "$LARGE_MB"
    printf "HIGH_FILES=%s\n"       "$HIGH_FILES"
    printf "EXCLUDE_TMP_ROOT=%s\n" "$EXCLUDE_TMP_ROOT"
    printf "SKIP_ACL=%s\n"         "$SKIP_ACL"
    printf "CHUNK_SIZE=%s\n"       "$CHUNK_SIZE"
    printf "PROG_INTERVAL=%s\n"    "$PROG_INTERVAL"
    printf "SKIP_REC=%s\n"         "$SKIP_REC"
    printf "SKIP_DU=%s\n"          "$SKIP_DU"
    printf "COUNT_MATCHED_DIRS=%s\n" "$COUNT_MATCHED_DIRS"
    printf "FIND_TIMEOUT=%s\n"     "$FIND_TIMEOUT"
    printf "RESUME_ENABLED=%s\n"   "$RESUME_ENABLED"
    printf "MAX_TMP_MB=%s\n"       "$MAX_TMP_MB"
    printf "LOG_TIMING=%s\n"       "$LOG_TIMING"
  } >"$CONF_FILE"
  tlog "Config saved: $CONF_FILE"
}

###############################################################################
# SECTION 6 — PROGRESS BAR
#
# All progress output goes to /dev/tty only — never pollutes stdout/logs.
# _PTTY  : /dev/tty path (empty string when unavailable)
# _PACT  : 1 = bar line currently on screen; needs clearing before newline output
# _BAR_W : bar width in characters (30)
#
# Functions defined here (called from scan_root and run_remediation below):
#   prog_init   — open /dev/tty, reset state
#   prog_clear  — erase current bar line before printing newline output
#   prog_done   — alias for prog_clear at end of phase
#   prog_phase  — print a phase header on a clean line
#   prog_high   — print a HIGH finding on a clean line
#   _mkbar      — build the [====>  ] NNN% string (no subprocesses)
#   prog_bar    — update discovery progress bar (ETA computed inline)
#   prog_rem    — update remediation progress bar
#
# CRITICAL: There is NO progress_eta function anywhere in this script.
#           ETA is computed inline inside prog_bar using a single perl call.
###############################################################################
_PTTY=""
_PACT=0
_BAR_W=30

prog_init() {
  if [[ -w /dev/tty ]]; then
    _PTTY="/dev/tty"
  else
    _PTTY=""
  fi
  _PACT=0
}

prog_clear() {
  if [[ -n "$_PTTY" && $_PACT -eq 1 ]]; then
    printf "\r%-110s\r" " " >"$_PTTY"
    _PACT=0
  fi
}

prog_done() {
  prog_clear
}

prog_phase() {
  [[ -z "$_PTTY" ]] && return
  prog_clear
  printf "  >> %s\n" "$1" >"$_PTTY"
}

prog_high() {
  # prog_high <path>  — always HIGH, print on its own clean line
  [[ -z "$_PTTY" ]] && return
  prog_clear
  printf "  [HIGH  ] %s\n" "$1" >"$_PTTY"
}

_mkbar() {
  # _mkbar <done> <total>
  # ksh88-safe: plain if/fi, no ternary, pure string loop (no subprocesses)
  typeset _D="$1" _T="$2"
  typeset _PCT=0 _F=0 _E=0 _I=0
  typeset _BF="" _BE="" _AR=""

  if [[ $_T -gt 0 ]]; then
    _PCT=$(( _D * 100 / _T ))
    _F=$(( _D * _BAR_W / _T ))
  fi
  if [[ $_F -gt $_BAR_W ]]; then
    _F=$_BAR_W
  fi
  _E=$(( _BAR_W - _F ))

  _I=0
  while [[ $_I -lt $_F ]]; do
    _BF="${_BF}="
    _I=$(( _I + 1 ))
  done

  _I=0
  while [[ $_I -lt $_E ]]; do
    _BE="${_BE} "
    _I=$(( _I + 1 ))
  done

  if [[ $_F -lt $_BAR_W ]]; then
    _AR=">"
  fi

  printf "[%s%s%s] %3d%%" "$_BF" "$_AR" "$_BE" "$_PCT"
}

prog_bar() {
  # prog_bar <scanned> <matched> <curpath> <t0_epoch> <total_candidates>
  # ETA computed inline — NO call to any separate ETA function
  typeset _SC="$1" _MT="$2" _CP="$3" _T0="$4" _TOT="$5"
  [[ -z "$_PTTY" ]] && return

  typeset _BAR
  _BAR=$(_mkbar "$_SC" "$_TOT")

  # ETA: single perl call, no separate function, integers only
  typeset _ETA=""
  if [[ $PERL_OK -eq 1 && $_T0 -gt 0 && $_SC -gt 0 && $_TOT -gt $_SC ]]; then
    _ETA=$(perl -e "
      my \$el = time() - $_T0;
      if (\$el > 0) {
        my \$rem  = $_TOT - $_SC;
        my \$rate = $_SC / \$el;
        my \$s    = int(\$rem / \$rate);
        if    (\$s >= 3600) { printf '  ETA ~%dh%02dm', int(\$s/3600), int((\$s%%3600)/60) }
        elsif (\$s >= 60)   { printf '  ETA ~%dm%02ds', int(\$s/60), \$s%%60 }
        else                { printf '  ETA ~%ds', \$s }
      }
    " 2>/dev/null)
  fi

  # Truncate current path to 28 chars
  typeset _DP
  _DP=$(printf "%s" "$_CP" | awk '{
    s = $0
    if (length(s) > 28) s = "..." substr(s, length(s) - 27)
    print s
  }')

  printf "\r  %s  Found:%-5d  %-28s%s" \
    "$_BAR" "$_MT" "$_DP" "$_ETA" >"$_PTTY"
  _PACT=1
}

prog_rem() {
  # prog_rem <done> <planned> <path> <result>
  typeset _D="$1" _PL="$2" _P="$3" _R="$4"
  [[ -z "$_PTTY" ]] && return

  typeset _BAR
  _BAR=$(_mkbar "$_D" "$_PL")

  typeset _DP
  _DP=$(printf "%s" "$_P" | awk '{
    s = $0
    if (length(s) > 35) s = "..." substr(s, length(s) - 34)
    print s
  }')

  printf "\r  %s  %-6s  %-35s" "$_BAR" "$_R" "$_DP" >"$_PTTY"
  _PACT=1
}

###############################################################################
# SECTION 7 — PERL CHECK (done once at startup)
###############################################################################
PERL_OK=0
command -v perl >/dev/null 2>&1 && PERL_OK=1

###############################################################################
# SECTION 8 — TIMING HELPERS
###############################################################################
epoch_now() {
  if [[ $PERL_OK -eq 1 ]]; then
    perl -e 'print time()' 2>/dev/null
  else
    printf "0"
  fi
}

elapsed_str() {
  typeset _T0="$1"
  if [[ $PERL_OK -ne 1 ]]; then
    printf "?"
    return
  fi
  typeset _NOW _S
  _NOW=$(epoch_now)
  _S=$(( _NOW - _T0 ))
  if [[ $_S -ge 3600 ]]; then
    printf "%dh%02dm%02ds" $(( _S / 3600 )) $(( (_S % 3600) / 60 )) $(( _S % 60 ))
  elif [[ $_S -ge 60 ]]; then
    printf "%dm%02ds" $(( _S / 60 )) $(( _S % 60 ))
  else
    printf "%ds" "$_S"
  fi
}

###############################################################################
# SECTION 9 — FAST STAT
# Single perl lstat() call returns all needed fields in one subprocess.
# Replaces: get_octal + get_og + get_mtime + get_adays (4 subprocesses → 1)
# Output (tab-separated): octal  owner  group  mtime  atime_days  size_kb
###############################################################################
fast_stat() {
  [[ $PERL_OK -ne 1 ]] && return 1
  perl -e '
    use POSIX qw(strftime);
    my @s = lstat($ARGV[0]);
    exit 1 unless @s;
    printf "%s\t%s\t%s\t%s\t%d\t%d\n",
      sprintf("%04o", $s[2] & 07777),
      (getpwuid($s[4]) || $s[4]),
      (getgrgid($s[5]) || $s[5]),
      strftime("%b %d %H:%M", localtime($s[9])),
      int((time() - $s[8]) / 86400),
      int($s[7] / 1024);
  ' "$1" 2>/dev/null
}

# Globals set by parse_fs:
_FS_OCT="" _FS_OWN="" _FS_GRP="" _FS_MTM="" _FS_ATD="" _FS_SKB=""

parse_fs() {
  typeset _L="$1"
  _FS_OCT=$(printf "%s" "$_L" | awk -F'\t' '{print $1}')
  _FS_OWN=$(printf "%s" "$_L" | awk -F'\t' '{print $2}')
  _FS_GRP=$(printf "%s" "$_L" | awk -F'\t' '{print $3}')
  _FS_MTM=$(printf "%s" "$_L" | awk -F'\t' '{print $4}')
  _FS_ATD=$(printf "%s" "$_L" | awk -F'\t' '{print $5}')
  _FS_SKB=$(printf "%s" "$_L" | awk -F'\t' '{print $6}')
}

###############################################################################
# SECTION 10 — PERMISSION PRIMITIVES (fallback when perl unavailable)
###############################################################################
get_octal() {
  if [[ $PERL_OK -eq 1 ]]; then
    perl -e '
      my @s = stat($ARGV[0]);
      exit 1 unless @s;
      printf "%04o\n", $s[2] & 07777;
    ' "$1" 2>/dev/null
    return
  fi
  ls -ld "$1" 2>/dev/null | awk '{print $1}' | awk '
    function bv(c, x) { return (c == x) ? 1 : 0 }
    {
      s = $0
      u = bv(substr(s,2,1),"r")*4 + bv(substr(s,3,1),"w")*2 + \
          (substr(s,4,1) ~ /[xsS]/ ? 1 : 0)
      g = bv(substr(s,5,1),"r")*4 + bv(substr(s,6,1),"w")*2 + \
          (substr(s,7,1) ~ /[xsS]/ ? 1 : 0)
      o = bv(substr(s,8,1),"r")*4 + bv(substr(s,9,1),"w")*2 + \
          (substr(s,10,1) ~ /[xtT]/ ? 1 : 0)
      sp = 0
      if (substr(s,4,1)  ~ /[sS]/) sp += 4
      if (substr(s,7,1)  ~ /[sS]/) sp += 2
      if (substr(s,10,1) ~ /[tT]/) sp += 1
      printf "%04o\n", sp * 512 + u * 64 + g * 8 + o
    }'
}

get_og()    { ls -ld "$1" 2>/dev/null | awk '{print $3 ":" $4}'; }
get_mtime() { ls -ld "$1" 2>/dev/null | awk '{print $6 " " $7 " " $8}'; }
get_size_kb() { du -sk "$1" 2>/dev/null | awk 'NR==1{print $1}'; }

get_adays() {
  if [[ $PERL_OK -eq 1 ]]; then
    perl -e '
      my @s = stat($ARGV[0]);
      exit 1 unless @s;
      printf "%d\n", int((time() - $s[8]) / 86400);
    ' "$1" 2>/dev/null
    return
  fi
  printf "999\n"
}

get_type() {
  if   [[ -L "$1" ]]; then printf "symlink\n"
  elif [[ -d "$1" ]]; then printf "directory\n"
  elif [[ -f "$1" ]]; then printf "file\n"
  else                     printf "other\n"
  fi
}

count_rec() {
  # Quote path fully — handles special chars like + spaces brackets
  find "$1" -xdev 2>/dev/null | wc -l | awk '{print $1+0}'
}

acl_marker() {
  if [[ $SKIP_ACL -eq 1 ]]; then
    printf "skipped\n"
    return
  fi
  # Double-quote path — handles + spaces and other special chars in AIX paths
  typeset _PF
  _PF=$(ls -ld "$1" 2>/dev/null | awk '{print $1}')
  case "$_PF" in
    *+) printf "YES\n" ;;
    *)  printf "NO\n"  ;;
  esac
}

save_acl() {
  command -v aclget >/dev/null 2>&1 || return 1
  # Quote both path args
  aclget "$1" >"$2" 2>/dev/null
}

csv_q()  { printf '"%s"' "$(printf "%s" "$1" | sed 's/"/""/g')"; }
csv_uq() { printf "%s"   "$(printf "%s" "$1" | sed 's/^"//; s/"$//')"; }

###############################################################################
# SECTION 11 — PERMISSION MODE MATCHING
###############################################################################
perm_matches() {
  typeset _OCT="$1" _TYPE="$2" _MODE="$3"

  if [[ $PERL_OK -eq 1 ]]; then
    case "$_MODE" in
      WW)
        perl -e 'exit((oct($ARGV[0]) & 0002) ? 0 : 1);' "$_OCT" 2>/dev/null
        return $?
        ;;
      777)
        perl -e 'exit(oct($ARGV[0]) == 0777 ? 0 : 1);' "$_OCT" 2>/dev/null
        return $?
        ;;
      777D)
        if [[ "$_TYPE" = "directory" ]]; then
          perl -e '
            my $m = oct($ARGV[0]);
            exit(($m == 0777 || $m == 01777) ? 0 : 1);
          ' "$_OCT" 2>/dev/null
          return $?
        else
          perl -e 'exit(oct($ARGV[0]) == 0777 ? 0 : 1);' "$_OCT" 2>/dev/null
          return $?
        fi
        ;;
    esac
  fi

  # Fallback without perl: WW mode only, last octal digit
  if [[ "$_MODE" = "WW" ]]; then
    typeset _LAST
    _LAST=$(printf "%s" "$_OCT" | awk '{print substr($0, length($0), 1)}')
    if (( (_LAST & 2) != 0 )); then
      return 0
    fi
  fi
  return 1
}

###############################################################################
# SECTION 12 — CANDIDATE MODE DETECTION
###############################################################################
_USE_FIND_PERM=0

detect_cand_mode() {
  typeset _SM="$1" _CM="$2"
  _USE_FIND_PERM=0

  # Only WW mode can use find -perm -002
  if [[ "$_SM" != "WW" ]]; then
    return
  fi

  case "$_CM" in
    STAT) _USE_FIND_PERM=0; return ;;
    FIND) _USE_FIND_PERM=1; return ;;
  esac

  # AUTO: probe /tmp to confirm find -perm works correctly on this AIX
  if [[ -d /tmp ]]; then
    typeset _O
    _O=$(get_octal /tmp)
    if perm_matches "$_O" "directory" "WW"; then
      typeset _PR
      _PR=$(find /tmp -xdev -prune -perm -002 -print 2>/dev/null)
      if [[ "$_PR" = "/tmp" ]]; then
        _USE_FIND_PERM=1
      fi
    fi
  fi
}

###############################################################################
# SECTION 13 — RISK CLASSIFICATION
###############################################################################
_RISK_JUST=""

classify_risk() {
  typeset _P="$1" _TY="$2" _SKB="$3" _AD="$4" _RC="$5" _ACL="$6" _OCT="$7"
  typeset _RISK="LOW" _JUST="" _SMB
  _SMB=$(( _SKB / 1024 ))

  if [[ "$_TY" = "directory" ]]; then
    if [[ $_RC -gt $HIGH_FILES ]]; then
      _RISK="HIGH"
      _JUST="${_JUST}Recursive items (${_RC}>${HIGH_FILES}); "
    fi
    if [[ $_SMB -gt $LARGE_MB ]]; then
      _RISK="HIGH"
      _JUST="${_JUST}Large dir (${_SMB}MB>${LARGE_MB}MB); "
    fi
  fi

  if [[ $_AD -lt 7 ]]; then
    _RISK="HIGH"
    _JUST="${_JUST}Recently accessed (${_AD}d<7d); "
  fi

  case "$_P" in
    /download/in|/cdirect/in|/download/out|/badata/out)
      _RISK="HIGH"
      _JUST="${_JUST}Known integration drop-zone; " ;;
    /download/scripts*|/cdirect/scripts*)
      _RISK="HIGH"
      _JUST="${_JUST}Script directory — integrity risk; " ;;
    /download|/cdirect)
      _RISK="HIGH"
      _JUST="${_JUST}Mount-point root — broad impact; " ;;
  esac

  if [[ "$_ACL" = "YES" ]]; then
    _RISK="HIGH"
    _JUST="${_JUST}ACL present — review before chmod; "
  fi

  if [[ "$_RISK" = "LOW" ]]; then
    if [[ $_AD -lt $RECENT_DAYS && $_AD -ge 7 ]]; then
      _RISK="MEDIUM"
      _JUST="${_JUST}Accessed within ${RECENT_DAYS}d (${_AD}d); "
    fi
  fi

  if [[ "$_RISK" = "LOW" ]]; then
    _JUST="${_JUST}World-writable detected (mode=${_OCT}); "
  fi

  _RISK_JUST=$(printf "%s" "$_JUST" | sed 's/; $//')
  printf "%s\n" "$_RISK"
}

###############################################################################
# SECTION 14 — REMEDIATION HINTS
###############################################################################
suggest_rem() {
  typeset _P="$1" _TY="$2"
  typeset _SM="" _SO="-" _SG="-" _SN=""

  if [[ "$_TY" = "directory" ]]; then
    case "$_P" in
      /tmp)
        _SM="1777"; _SO="root"; _SG="system"
        _SN="/tmp: expected sticky world-writable; do not remediate." ;;
      /download/in|/cdirect/in)
        _SM="1770"; _SO="cdirect"; _SG="cdirect"
        _SN="Drop zone: sticky. Validate accounts first." ;;
      /download/out|/badata/out)
        _SM="1770"; _SO="cdirect"; _SG="cdirect"
        _SN="Output zone: sticky. Validate app requirements." ;;
      /download/scripts*|/cdirect/scripts*)
        _SM="2750"; _SO="cdirect"; _SG="staff"
        _SN="Scripts: remove world; setgid preserves group." ;;
      *)
        _SM="2770"
        _SN="Directory: remove world write; confirm group membership." ;;
    esac
  else
    case "$_P" in
      *.sh|*.ksh|*.bash)
        _SM="0750"; _SN="Script: remove world perms (integrity risk)." ;;
      *.cfg|*.conf|*.ini|*.od|*.cd)
        _SM="0640"; _SN="Config: remove world perms." ;;
      *.csv|*.txt|*.log)
        _SM="0660"; _SN="Data/log: remove world; keep group rw." ;;
      *)
        _SM="0640"; _SN="File: conservative default." ;;
    esac
  fi

  printf "%s|%s|%s|%s\n" "$_SM" "$_SO" "$_SG" "$_SN"
}

###############################################################################
# SECTION 15 — CHECKPOINT / RESUME
###############################################################################
_CKPT_FILE=""
_CKPT_LINE=0

ckpt_init() {
  _CKPT_FILE="${1}/.scan_checkpoint"
  _CKPT_LINE=0
  if [[ $RESUME_ENABLED -eq 1 && -r "$_CKPT_FILE" ]]; then
    typeset _S
    _S=$(cat "$_CKPT_FILE" 2>/dev/null)
    if is_int "$_S"; then
      _CKPT_LINE=$_S
    fi
    if [[ $_CKPT_LINE -gt 0 ]]; then
      YELLOW "  Resume: skipping first $_CKPT_LINE candidates"
      flog "RESUME from line $_CKPT_LINE"
    fi
  fi
}

ckpt_save() {
  if [[ $RESUME_ENABLED -eq 1 && -n "$_CKPT_FILE" ]]; then
    printf "%d\n" "$1" >"$_CKPT_FILE" 2>/dev/null
  fi
}

ckpt_clear() {
  if [[ -n "$_CKPT_FILE" ]]; then
    rm -f "$_CKPT_FILE" 2>/dev/null
  fi
  _CKPT_LINE=0
}

###############################################################################
# SECTION 16 — SAFE CSV RESULT UPDATE
# Uses /tmp temp + cat redirect — avoids mv across filesystem boundaries
# which caused "0653-404 Unable to duplicate owner and mode" on AIX NFS mounts
###############################################################################
csv_set_result() {
  typeset _F="$1" _QP="$2" _OLD="$3" _NEW="$4"
  typeset _TMP="/tmp/.perm_hdn_upd_${HOST}_$$"
  awk -v p="$_QP" -v o="$_OLD" -v n="$_NEW" \
    'BEGIN{FS=OFS=","} {if($1==p && $10==o) $10=n; print}' \
    "$_F" >"$_TMP" 2>/dev/null
  if [[ $? -eq 0 && -s "$_TMP" ]]; then
    cat "$_TMP" >"$_F" 2>/dev/null
  fi
  rm -f "$_TMP"
}

###############################################################################
# SECTION 17 — DISCOVERY COUNTERS
###############################################################################
_DT=0   # total matched
_DH=0   # HIGH risk
_DM=0   # MEDIUM risk
_DL=0   # LOW risk
_DA=0   # items with ACL
_DE=0   # stat errors / skipped

###############################################################################
# SECTION 18 — PROCESS ONE CANDIDATE
###############################################################################
process_one() {
  typeset _P="$1" _MNT="$2" _DC="$3" _HC="$4" _SM="$5" _ET="$6"

  # Symlinks never processed
  if [[ -L "$_P" ]]; then return 0; fi

  # Guard: path may have vanished since find ran
  if [[ ! -e "$_P" ]]; then
    flog "SKIP vanished: $_P"
    _DE=$(( _DE + 1 ))
    return 0
  fi

  typeset _TYPE
  _TYPE=$(get_type "$_P")

  # Exclude /tmp root itself (not contents) when requested
  if [[ $_ET -eq 1 && "$_P" = "/tmp" && "$_TYPE" = "directory" ]]; then
    return 0
  fi

  # ── Fast path: single perl lstat() for all metadata ─────────────────────
  typeset _OCT _OWN _GRP _MTM _ATD _SKB
  typeset _FSL
  _FSL=$(fast_stat "$_P")

  if [[ -n "$_FSL" ]]; then
    parse_fs "$_FSL"
    _OCT="$_FS_OCT"
    _OWN="$_FS_OWN"
    _GRP="$_FS_GRP"
    _MTM="$_FS_MTM"
    _ATD="$_FS_ATD"
    if [[ $SKIP_DU -eq 1 ]]; then
      _SKB=0
    else
      _SKB=$(get_size_kb "$_P")
      [[ -z "$_SKB" ]] && _SKB=0
    fi
  else
    _OCT=$(get_octal "$_P")
    typeset _OG
    _OG=$(get_og "$_P")
    _OWN=$(printf "%s" "$_OG" | cut -d: -f1)
    _GRP=$(printf "%s" "$_OG" | cut -d: -f2)
    _MTM=$(get_mtime "$_P")
    _ATD=$(get_adays "$_P")
    if [[ $SKIP_DU -eq 1 ]]; then
      _SKB=0
    else
      _SKB=$(get_size_kb "$_P")
      [[ -z "$_SKB" ]] && _SKB=0
    fi
  fi

  # Validate octal
  if [[ -z "$_OCT" || "$_OCT" = "????" ]]; then
    flog "WARN: stat failed: $_P"
    _DE=$(( _DE + 1 ))
    return 0
  fi
  [[ -z "$_ATD" ]] && _ATD=999
  [[ -z "$_SKB" ]] && _SKB=0

  # Permission mode filter
  if ! perm_matches "$_OCT" "$_TYPE" "$_SM"; then
    return 0
  fi

  typeset _PAR
  _PAR=$(dirname "$_P")
  [[ -z "$_PAR" ]] && _PAR="/"

  typeset _ACL
  _ACL=$(acl_marker "$_P")
  if [[ "$_ACL" = "YES" ]]; then
    _DA=$(( _DA + 1 ))
  fi

  typeset _RC=1
  if [[ "$_TYPE" = "directory" ]]; then
    if [[ $SKIP_REC -eq 0 ]]; then
      # Full recursive count across all depths (slowest)
      _RC=$(count_rec "$_P")
    elif [[ $COUNT_MATCHED_DIRS -eq 1 ]]; then
      # Fast count: immediate children only via ls -1a
      # Path is double-quoted to handle special chars (+, spaces, etc.)
      # ls -1a includes . and .. so subtract 2 from result
      typeset _LSOUT
      _LSOUT=$(ls -1a "$_P" 2>/dev/null | wc -l | awk '{print $1+0}')
      if [[ $_LSOUT -ge 2 ]]; then
        _RC=$(( _LSOUT - 2 ))
      else
        _RC=0
      fi
    else
      _RC=-1    # -1 = counting disabled
    fi
  fi

  typeset _RISK
  _RISK=$(classify_risk "$_P" "$_TYPE" "$_SKB" "$_ATD" "$_RC" "$_ACL" "$_OCT")
  typeset _JUST="$_RISK_JUST"

  typeset _SUG _SMODE _SOWN _SGRP _SNOT
  _SUG=$(suggest_rem "$_P" "$_TYPE")
  _SMODE=$(printf "%s" "$_SUG" | cut -d'|' -f1)
  _SOWN=$( printf "%s" "$_SUG" | cut -d'|' -f2)
  _SGRP=$( printf "%s" "$_SUG" | cut -d'|' -f3)
  _SNOT=$( printf "%s" "$_SUG" | cut -d'|' -f4-)

  # Write discovery CSV row
  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "$(csv_q "$_P")"    "$(csv_q "$_TYPE")" "$(csv_q "$_OCT")" \
    "$(csv_q "$_OWN")"  "$(csv_q "$_GRP")"  "$(csv_q "$_MTM")" \
    "$(csv_q "$_SKB")"  "$(csv_q "$_PAR")"  "$(csv_q "$_RC")" \
    "$(csv_q "$_ACL")"  "$(csv_q "$_MNT")"  >>"$_DC"

  # Write hints CSV row
  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "$(csv_q "$_P")"     "$(csv_q "$_TYPE")"  "$(csv_q "$_RISK")" \
    "$(csv_q "$_JUST")"  "$(csv_q "$_OCT")"   "$(csv_q "$_OWN")" \
    "$(csv_q "$_GRP")"   "$(csv_q "$_SKB")"   "$(csv_q "$_RC")" \
    "$(csv_q "$_ACL")"   "$(csv_q "$_SMODE")" "$(csv_q "$_SOWN")" \
    "$(csv_q "$_SGRP")"  "$(csv_q "$_SNOT")"  >>"$_HC"

  _DT=$(( _DT + 1 ))
  case "$_RISK" in
    HIGH)   _DH=$(( _DH + 1 )) ;;
    MEDIUM) _DM=$(( _DM + 1 )) ;;
    LOW)    _DL=$(( _DL + 1 )) ;;
  esac

  # Surface HIGH findings immediately on terminal
  if [[ "$_RISK" = "HIGH" ]]; then
    prog_high "$_P"
  fi
}

###############################################################################
# SECTION 19 — SCAN ONE ROOT
#
# CRITICAL DESIGN NOTE:
# _SCAN_TOTAL is set immediately before the while-read loop in the SAME shell
# function scope. ksh88 while-read loops do NOT fork a subshell when reading
# from a file redirect (done <file). Variables set before the loop ARE visible
# inside it. This is why prog_bar receives a valid non-zero total.
###############################################################################
_SCAN_TOTAL=0

scan_root() {
  typeset _ROOT="$1" _DC="$2" _HC="$3" _SM="$4" _ET="$5" _OUTDIR="$6"

  if [[ ! -e "$_ROOT" ]]; then
    flog "WARN: not found: $_ROOT — skipping"
    return 0
  fi

  typeset _MNT
  _MNT=$(df "$_ROOT" 2>/dev/null | awk 'NR==2{print $NF}')
  [[ -z "$_MNT" ]] && _MNT="$_ROOT"

  flog "=== scan_root: $_ROOT  mount=$_MNT  mode=$_SM ==="
  prog_phase "Scanning $_ROOT  (mount: $_MNT)"

  # /tmp space guard
  typeset _TMPFK _TMPFM
  _TMPFK=$(df -k /tmp 2>/dev/null | awk 'NR==2{print $3}')
  _TMPFK=${_TMPFK:-0}
  _TMPFM=$(( _TMPFK / 1024 ))
  if [[ $_TMPFM -lt 200 ]]; then
    warn "/tmp only ${_TMPFM}MB free — large scans may fail"
    confirm "Continue anyway?" || return 1
  fi

  # Phase 1 — build candidate list via find
  prog_phase "Phase 1/2: Building file list under $_ROOT ..."
  typeset _TLIST="/tmp/.perm_hdn_cand_${HOST}_$$"
  typeset _T0F
  _T0F=$(epoch_now)

  if [[ $_USE_FIND_PERM -eq 1 ]]; then
    find "$_ROOT" -xdev \
      \( -name lost+found -o -name .snapshot -o -name .snapshots \) -prune \
      -o \( ! -type l -perm -002 \) -print 2>/dev/null >"$_TLIST"
  else
    find "$_ROOT" -xdev \
      \( -name lost+found -o -name .snapshot -o -name .snapshots \) -prune \
      -o ! -type l -print 2>/dev/null >"$_TLIST"
  fi
  tlog_timing "find: $(elapsed_str $_T0F)  root=$_ROOT"

  # Count candidates — awk strips all whitespace reliably
  typeset _CAND=0
  if [[ -f "$_TLIST" ]]; then
    _CAND=$(wc -l <"$_TLIST" | awk '{print $1+0}')
  fi
  flog "Candidates: $_CAND"

  if [[ $_CAND -eq 0 ]]; then
    prog_phase "No candidates found under $_ROOT"
    rm -f "$_TLIST"
    return 0
  fi

  # CRITICAL: _SCAN_TOTAL set HERE, before the loop, in the same scope
  _SCAN_TOTAL=$_CAND

  prog_phase "Phase 2/2: Checking permissions on $_CAND candidates ..."
  if [[ -n "$_PTTY" ]]; then
    printf "  (HIGH findings appear here as they are found)\n" >"$_PTTY"
  fi

  ckpt_init "$_OUTDIR"
  typeset _SKIP=$_CKPT_LINE
  typeset _T0P
  _T0P=$(epoch_now)

  typeset _LN=0 _CNUM=0 _CLN=0
  typeset _CTMP="/tmp/.perm_hdn_chunk_${HOST}_$$"

  while read _CP; do
    _LN=$(( _LN + 1 ))

    # Skip lines already processed in a previous interrupted run
    if [[ $_LN -le $_SKIP ]]; then
      continue
    fi

    # Accumulate into chunk file
    printf "%s\n" "$_CP" >>"${_CTMP}.${_CNUM}"
    _CLN=$(( _CLN + 1 ))

    # Flush completed chunk
    if [[ $_CLN -ge $CHUNK_SIZE ]]; then
      while read _CL; do
        [[ -n "$_CL" ]] && process_one "$_CL" "$_MNT" "$_DC" "$_HC" "$_SM" "$_ET"
      done <"${_CTMP}.${_CNUM}"
      rm -f "${_CTMP}.${_CNUM}"
      _CNUM=$(( _CNUM + 1 ))
      _CLN=0
      ckpt_save "$_LN"
      tlog_timing "chunk $_CNUM: ln=$_LN matched=$_DT elapsed=$(elapsed_str $_T0P)"
    fi

    # Update progress bar — _SCAN_TOTAL always valid in this scope
    typeset _MOD=$(( _LN % PROG_INTERVAL ))
    if [[ $_MOD -eq 0 ]]; then
      prog_bar "$_LN" "$_DT" "$_CP" "$_T0P" "$_SCAN_TOTAL"
    fi

  done <"$_TLIST"

  # Flush final partial chunk
  if [[ $_CLN -gt 0 ]]; then
    while read _CL; do
      [[ -n "$_CL" ]] && process_one "$_CL" "$_MNT" "$_DC" "$_HC" "$_SM" "$_ET"
    done <"${_CTMP}.${_CNUM}"
    rm -f "${_CTMP}.${_CNUM}"
  fi

  # Final 100% bar then clear
  prog_bar "$_LN" "$_DT" "complete" "$_T0P" "$_SCAN_TOTAL"
  prog_done

  tlog_timing "process: $(elapsed_str $_T0P)  root=$_ROOT  scanned=$_LN  matched=$_DT"
  ckpt_clear
  flog "=== scan_root done: root=$_ROOT  scanned=$_LN  matched=$_DT  high=$_DH ==="

  rm -f "$_TLIST"
  rm -f "${_CTMP}".* 2>/dev/null
}

###############################################################################
# SECTION 20 — RUN DISCOVERY
###############################################################################
run_discovery() {
  typeset _ROOTS="$1" _SM="$2" _CM="$3" _ET="$4"

  # Reset counters
  _DT=0; _DH=0; _DM=0; _DL=0; _DA=0; _DE=0
  prog_init

  typeset _TS
  _TS=$(date +%Y%m%d_%H%M)
  typeset _STS
  _STS=$(date '+%Y-%m-%d %H:%M:%S')

  typeset _LBL
  _LBL=$(printf "%s" "$_ROOTS" | awk '{print $1}' | sed 's:^/::; s:/:_:g')

  typeset _OUTDIR="${BASE_OUT}/discovery_${_TS}"
  mkdir -p "$_OUTDIR" || die "Cannot create output dir: $_OUTDIR"

  _LOGFILE="${_OUTDIR}/discover_${_TS}.log"
  typeset _DC="${_OUTDIR}/discovery_perm_${_LBL}_${_TS}.csv"
  typeset _HC="${_OUTDIR}/hints_perm_${_LBL}_${_TS}.csv"
  typeset _ST="${_OUTDIR}/summary_perm_${_LBL}_${_TS}.txt"

  : >"$_LOGFILE" >"$_DC" >"$_HC"

  flog "=== perm_hardening_aix.ksh v${VERSION} — Discovery ==="
  flog "Roots=$_ROOTS  Mode=$_SM  Cand=$_CM  ExclTmp=$_ET"
  if [[ $PERL_OK -ne 1 ]]; then
    flog "WARN: perl not found — exact 777 matching unreliable"
  fi

  # Discovery CSV header
  # ITEM_COUNT column:
  #   N    = immediate child count (COUNT_MATCHED_DIRS=1, fast default)
  #   N    = full recursive count  (SKIP_REC=0)
  #  -1    = counting disabled     (SKIP_REC=1, COUNT_MATCHED_DIRS=0)
  #   1    = object is a file (not a directory)
  # SIZE_KB column:
  #   0    = SKIP_DU=1 (default for performance)
  #   N    = actual size in KB when SKIP_DU=0
  # NOTE: paths containing special chars (+ spaces brackets) are handled
  #       by quoting all ls/find/du calls throughout this script
  printf "FULL_PATH,OBJECT_TYPE,CURRENT_PERMISSION,OWNER,GROUP," >"$_DC"
  printf "LAST_MODIFIED,SIZE_KB,PARENT_DIRECTORY," >>"$_DC"
  printf "ITEM_COUNT,ACL_SET,MOUNT_POINT\n" >>"$_DC"

  # Hints CSV header
  printf "FULL_PATH,OBJECT_TYPE,RISK_LEVEL,RISK_JUSTIFICATION," >"$_HC"
  printf "CURRENT_PERMISSION,OWNER,GROUP,SIZE_KB," >>"$_HC"
  printf "ITEM_COUNT,ACL_SET," >>"$_HC"
  printf "SUGGESTED_MODE,SUGGESTED_OWNER,SUGGESTED_GROUP,NOTES\n" >>"$_HC"

  detect_cand_mode "$_SM" "$_CM"
  if [[ $_USE_FIND_PERM -eq 1 ]]; then
    flog "Candidate filter: FIND(-perm -002)"
  else
    flog "Candidate filter: STAT(enumerate+check)"
  fi

  typeset _T0ALL
  _T0ALL=$(epoch_now)

  typeset _R
  for _R in $_ROOTS; do
    typeset _T0R
    _T0R=$(epoch_now)
    scan_root "$_R" "$_DC" "$_HC" "$_SM" "$_ET" "$_OUTDIR"
    tlog_timing "root=$_R elapsed=$(elapsed_str $_T0R) total=$(elapsed_str $_T0ALL)"
  done

  typeset _ETS
  _ETS=$(date '+%Y-%m-%d %H:%M:%S')

  # Summary — printed to terminal and saved to file
  {
    printf "%s\n" "$SEP"
    printf " Permission Discovery Summary — v%s\n" "$VERSION"
    printf "%s\n" "$SEP"
    printf " Host:           %s\n" "$HOST"
    printf " Scan roots:     %s\n" "$_ROOTS"
    printf " Perm mode:      %s\n" "$_SM"
    if [[ $_USE_FIND_PERM -eq 1 ]]; then
      printf " Candidate:      FIND(-perm -002)\n"
    else
      printf " Candidate:      STAT(filter)\n"
    fi
    if [[ $_ET -eq 1 ]]; then
      printf " Exclude /tmp:   YES\n"
    else
      printf " Exclude /tmp:   NO\n"
    fi
    printf " Started:        %s\n" "$_STS"
    printf " Completed:      %s\n" "$_ETS"
    if [[ $SKIP_ACL -eq 1 ]]; then
      printf " ACL check:      skipped\n"
    else
      printf " ACL check:      enabled\n"
    fi
    printf " Thresholds:     recent=%dd  large=%dMB  high_files=%d\n" \
      "$RECENT_DAYS" "$LARGE_MB" "$HIGH_FILES"
    printf "\n RESULTS:\n"
    printf "   Total matching items:   %d\n" "$_DT"
    printf "   HIGH risk:              %d\n" "$_DH"
    printf "   MEDIUM risk:            %d\n" "$_DM"
    printf "   LOW risk:               %d\n" "$_DL"
    printf "   Items with ACL (+):     %d\n" "$_DA"
    printf "   Stat errors/skipped:    %d\n" "$_DE"
    printf "\n PERFORMANCE SETTINGS USED:\n"
    printf "   Chunk size:             %d\n" "$CHUNK_SIZE"
    printf "   Progress interval:      every %d candidates\n" "$PROG_INTERVAL"
    if [[ $SKIP_REC -eq 1 ]]; then
      printf "   Skip recursive count:   YES\n"
    else
      printf "   Skip recursive count:   NO\n"
    fi
    if [[ $SKIP_DU -eq 1 ]]; then
      printf "   Skip du:                YES\n"
    else
      printf "   Skip du:                NO\n"
    fi
    if [[ $FIND_TIMEOUT -gt 0 ]]; then
      printf "   Find timeout:           %ds\n" "$FIND_TIMEOUT"
    else
      printf "   Find timeout:           none\n"
    fi
    if [[ $RESUME_ENABLED -eq 1 ]]; then
      printf "   Resume enabled:         YES\n"
    else
      printf "   Resume enabled:         NO\n"
    fi
    printf "\n OUTPUT FILES:\n"
    printf "   Discovery CSV:  %s\n" "$_DC"
    printf "   Hints CSV:      %s\n" "$_HC"
    printf "   Summary:        %s\n" "$_ST"
    printf "   Log:            %s\n" "$_LOGFILE"
    printf "\n ITEM_COUNT column meaning:\n"
    if [[ $SKIP_REC -eq 0 ]]; then
      printf "   Directories: full recursive inode count\n"
    elif [[ $COUNT_MATCHED_DIRS -eq 1 ]]; then
      printf "   Directories: immediate child count (ls -1a)\n"
    else
      printf "   Directories: -1 (counting disabled)\n"
    fi
    printf "   Files:       always 1\n"
    printf "%s\n" "$SEP"
  } | tee "$_ST"

  # run.meta — machine-readable metadata used by the menu
  {
    printf "HOST=%s\n"          "$HOST"
    printf "VERSION=%s\n"       "$VERSION"
    printf "CREATED=%s\n"       "$_STS"
    printf "COMPLETED=%s\n"     "$_ETS"
    printf "ROOTS=%s\n"         "$_ROOTS"
    printf "MODE=%s\n"          "$_SM"
    printf "TOTAL=%d\n"         "$_DT"
    printf "HIGH=%d\n"          "$_DH"
    printf "MEDIUM=%d\n"        "$_DM"
    printf "LOW=%d\n"           "$_DL"
    printf "DISCOVERY_CSV=%s\n" "$(basename "$_DC")"
    printf "HINTS_CSV=%s\n"     "$(basename "$_HC")"
  } >"${_OUTDIR}/run.meta"

  flog "Done: TOTAL=$_DT HIGH=$_DH MED=$_DM LOW=$_DL ERR=$_DE"
  _LOGFILE=""

  printf "\nRun directory: %s\n" "$_OUTDIR"
}

###############################################################################
# SECTION 21 — REMEDIATION HELPERS
###############################################################################
get_hint_field() {
  typeset _HC="$1" _P="$2" _COL="$3"
  if [[ -z "$_HC" || ! -r "$_HC" ]]; then
    printf ""
    return
  fi
  awk -F',' -v p="\"${_P}\"" -v c="$_COL" \
    'NR>1 && $1==p { gsub(/^"|"$/, "", $c); print $c; exit }' \
    "$_HC" 2>/dev/null
}

plan_target() {
  typeset _HC="$1" _P="$2" _OM="$3" _OO="$4" _OG="$5"
  typeset _NM="$_OM" _NO="$_OO" _NG="$_OG"

  if [[ -z "$_NM" && -n "$_HC" ]]; then
    _NM=$(get_hint_field "$_HC" "$_P" 11)
  fi
  if [[ -z "$_NO" && -n "$_HC" ]]; then
    _NO=$(get_hint_field "$_HC" "$_P" 12)
  fi
  if [[ -z "$_NG" && -n "$_HC" ]]; then
    _NG=$(get_hint_field "$_HC" "$_P" 13)
  fi

  [[ -z "$_NO" ]] && _NO="-"
  [[ -z "$_NG" ]] && _NG="-"

  # Normalise 3-digit mode to 4-digit
  typeset _NML=${#_NM}
  if [[ $_NML -eq 3 ]]; then
    _NM="0${_NM}"
  fi

  printf "%s|%s|%s\n" "$_NM" "$_NO" "$_NG"
}

in_scope() {
  typeset _P="$1" _TP="$2" _TD="$3" _FL="$4" _HC="$5"

  if [[ -n "$_TP" ]]; then
    if [[ "$_P" = "$_TP" ]]; then return 0; else return 1; fi
  fi

  if [[ -n "$_TD" ]]; then
    case "$_P" in
      "$_TD"|"$_TD"/*) return 0 ;;
      *)               return 1 ;;
    esac
  fi

  if [[ -n "$_FL" ]]; then
    if [[ "$_FL" = "ALL" ]]; then
      return 0
    fi
    typeset _RV
    _RV=$(get_hint_field "$_HC" "$_P" 3)
    if [[ "$_RV" = "$_FL" ]]; then return 0; else return 1; fi
  fi

  return 0
}

###############################################################################
# SECTION 22 — BUILD ROLLBACK SCRIPT
###############################################################################
build_rollback() {
  typeset _TC="$1" _RB="$2"
  if [[ ! -s "$_TC" ]]; then return 0; fi

  typeset _NOW
  _NOW=$(date '+%Y-%m-%d %H:%M:%S')

  {
    printf '#!/bin/ksh\n'
    printf '# Rollback script — perm_hardening_aix.ksh v%s\n' "$VERSION"
    printf '# Host: %s  Generated: %s\n' "$HOST" "$_NOW"
    printf '# Usage: ksh %s [-n]   (-n = dry-run, no changes)\n\n' \
      "$(basename "$_RB")"
    printf 'PATH=/usr/bin:/bin:/usr/sbin:/sbin\n'
    printf 'DRY=0\n'
    printf '[ "$1" = "-n" ] && DRY=1\n'
    printf 'FAIL=0\n'
    printf 'TC="%s"\n\n' "$_TC"
    printf '_log() {\n'
    printf '  printf "%%s [ROLLBACK] %%s\\n" \\\n'
    printf '    "$(date '"'"'+%%Y-%%m-%%d %%H:%%M:%%S'"'"')" "$*"\n'
    printf '}\n'
    printf '_run() {\n'
    printf '  if [ $DRY -eq 1 ]; then\n'
    printf '    _log "DRYRUN: $*"\n'
    printf '  else\n'
    printf '    eval "$@" && _log "OK: $*" || {\n'
    printf '      _log "FAIL: $*"\n'
    printf '      FAIL=$(( FAIL + 1 ))\n'
    printf '    }\n'
    printf '  fi\n'
    printf '}\n\n'
    printf '[ $DRY -eq 1 ] && _log "=== DRY-RUN rollback ==="\n'
    printf '[ $DRY -eq 0 ] && _log "=== APPLYING rollback ==="\n\n'
    printf 'tail -n +2 "$TC" | while IFS="," read QP QT QOM QOO QOG QOA QNM QNO QNG QR; do\n'
    printf '  P=$(printf "%%s"  "$QP"  | sed '"'"'s/^"//; s/"$//'"'"')\n'
    printf '  OM=$(printf "%%s" "$QOM" | sed '"'"'s/^"//; s/"$//'"'"')\n'
    printf '  OO=$(printf "%%s" "$QOO" | sed '"'"'s/^"//; s/"$//'"'"')\n'
    printf '  OG=$(printf "%%s" "$QOG" | sed '"'"'s/^"//; s/"$//'"'"')\n'
    printf '  OA=$(printf "%%s" "$QOA" | sed '"'"'s/^"//; s/"$//'"'"')\n'
    printf '  [ -z "$P" ] && continue\n'
    printf '  [ -L "$P" ] && { _log "SKIP symlink: $P"; continue; }\n'
    printf '  [ ! -e "$P" ] && { _log "MISSING: $P"; continue; }\n'
    printf '  [ -n "$OM" ] && [ "$OM" != "-" ] && _run "chmod $OM '"'"'$P'"'"'"\n'
    printf '  if [ -n "$OO" ] && [ "$OO" != "-" ] &&\n'
    printf '     [ -n "$OG" ] && [ "$OG" != "-" ]; then\n'
    printf '    _run "chown $OO:$OG '"'"'$P'"'"'"\n'
    printf '  elif [ -n "$OO" ] && [ "$OO" != "-" ]; then\n'
    printf '    _run "chown $OO '"'"'$P'"'"'"\n'
    printf '  elif [ -n "$OG" ] && [ "$OG" != "-" ]; then\n'
    printf '    _run "chgrp $OG '"'"'$P'"'"'"\n'
    printf '  fi\n'
    printf '  if command -v aclput >/dev/null 2>&1 &&\n'
    printf '     [ -n "$OA" ] && [ -s "$OA" ]; then\n'
    printf '    _run "aclput -i '"'"'$OA'"'"' '"'"'$P'"'"'"\n'
    printf '  fi\n'
    printf 'done\n\n'
    printf '_log "Rollback complete. failures=$FAIL"\n'
    printf '[ $FAIL -gt 0 ] && exit 1\n'
    printf 'exit 0\n'
  } >"$_RB"

  chmod 700 "$_RB" 2>/dev/null
  flog "Rollback script created: $_RB"
}

###############################################################################
# SECTION 23 — RUN REMEDIATION
###############################################################################
_RP=0; _RA=0; _RS=0; _RF=0

run_remediation() {
  typeset _DC="$1"  _HC="$2"   _OD="$3"  _TP="$4"  _TD="$5"
  typeset _FL="$6"  _OM="$7"   _OO="$8"  _OG="$9"  _DRY="${10}"
  _RP=0; _RA=0; _RS=0; _RF=0
  prog_init

  typeset _TS
  _TS=$(date +%Y%m%d_%H%M%S)
  mkdir -p "$_OD" || die "Cannot create remediation dir: $_OD"

  _LOGFILE="${_OD}/remediate_${_TS}.log"
  typeset _TC="${_OD}/remediate_touched_${_TS}.csv"
  typeset _RB="${_OD}/rollback_permissions_${_TS}.sh"
  typeset _AD="${_OD}/acl_backup_${_TS}"
  mkdir -p "$_AD" 2>/dev/null

  flog "=== Remediation: dry=$_DRY ==="
  flog "dc=$_DC  hc=$_HC"
  flog "Scope: tp='$_TP' td='$_TD' fl='$_FL'"
  flog "Override: mode='$_OM' owner='$_OO' group='$_OG'"

  # Touched CSV header
  printf "FULL_PATH,OBJECT_TYPE,OLD_MODE,OLD_OWNER,OLD_GROUP," >"$_TC"
  printf "OLD_ACL_FILE,NEW_MODE,NEW_OWNER,NEW_GROUP,RESULT\n" >>"$_TC"

  if [[ $_DRY -eq 0 ]]; then
    printf "\n%s\n" "$SEP"
    printf " Output dir:      %s\n" "$_OD"
    printf " Touched CSV:     %s\n" "$_TC"
    printf " ACL backup:      %s\n" "$_AD"
    printf " Rollback script: %s\n" "$_RB"
    printf "%s\n" "$SEP"
    confirm_yes "Apply remediation changes?" || {
      printf "Aborted.\n"
      _LOGFILE=""
      return 1
    }
  else
    printf "\n%s\n" "$SEP"
    YELLOW " DRY-RUN MODE — no changes will be made"
    printf "%s\n" "$SEP"
  fi

  typeset _LN=0
  while IFS=',' read _QP _QT _QPERM _QOWN _QGRP _QMTM _QSKB _QPAR _QRC _QACL _QMNT; do
    _LN=$(( _LN + 1 ))
    if [[ $_LN -eq 1 ]]; then continue; fi   # skip header

    typeset _P
    _P=$(csv_uq "$_QP")
    [[ -z "$_P" ]] && continue

    if ! in_scope "$_P" "$_TP" "$_TD" "$_FL" "$_HC"; then
      continue
    fi

    if [[ -L "$_P" ]]; then
      _RS=$(( _RS + 1 ))
      flog "SKIP symlink: $_P"
      continue
    fi
    if [[ ! -e "$_P" ]]; then
      _RS=$(( _RS + 1 ))
      flog "MISSING: $_P"
      continue
    fi

    typeset _PLAN _NM _NO _NG
    _PLAN=$(plan_target "$_HC" "$_P" "$_OM" "$_OO" "$_OG")
    _NM=$(printf "%s" "$_PLAN" | cut -d'|' -f1)
    _NO=$(printf "%s" "$_PLAN" | cut -d'|' -f2)
    _NG=$(printf "%s" "$_PLAN" | cut -d'|' -f3)

    if [[ -z "$_NM" ]]; then
      _RS=$(( _RS + 1 ))
      flog "SKIP no mode resolved: $_P"
      continue
    fi

    # Capture pre-state
    typeset _PMOD _POG _POWN _PGRP
    _PMOD=$(get_octal "$_P")
    _POG=$(get_og "$_P")
    _POWN=$(printf "%s" "$_POG" | cut -d: -f1)
    _PGRP=$(printf "%s" "$_POG" | cut -d: -f2)

    # ACL pre-save
    typeset _PAF="-"
    typeset _PAM
    _PAM=$(acl_marker "$_P")
    if [[ "$_PAM" = "YES" ]]; then
      typeset _SN
      _SN=$(printf "%s" "$_P" | sed 's:/:_:g; s:^_::')
      _PAF="${_AD}/${_SN}_${_TS}.acl"
      save_acl "$_P" "$_PAF" || { warn "ACL save failed: $_P"; _PAF="-"; }
    fi

    # Already at target state? Skip if so.
    typeset _ALREADY=1
    if [[ "$_PMOD" != "$_NM" ]]; then _ALREADY=0; fi
    if [[ "$_NO" != "-" && -n "$_NO" && "$_POWN" != "$_NO" ]]; then _ALREADY=0; fi
    if [[ "$_NG" != "-" && -n "$_NG" && "$_PGRP" != "$_NG" ]]; then _ALREADY=0; fi

    if [[ $_ALREADY -eq 1 ]]; then
      _RS=$(( _RS + 1 ))
      flog "SKIP already compliant: $_P"
      continue
    fi

    _RP=$(( _RP + 1 ))
    typeset _TYPE
    _TYPE=$(get_type "$_P")

    # Display strings — (keep:x) instead of bare - for clarity
    typeset _DNO="$_NO" _DNG="$_NG"
    if [[ "$_NO" = "-" || -z "$_NO" ]]; then _DNO="(keep:${_POWN})"; fi
    if [[ "$_NG" = "-" || -z "$_NG" ]]; then _DNG="(keep:${_PGRP})"; fi

    # Show [PLAN] lines during dry-run only — not during apply
    if [[ $_DRY -eq 1 ]]; then
      prog_clear
      printf "[PLAN] %s  %s->%s  %s:%s -> %s:%s\n" \
        "$_P" "$_PMOD" "$_NM" "$_POWN" "$_PGRP" "$_DNO" "$_DNG"
    fi
    flog "PLAN: $_P  ${_PMOD}->${_NM}  ${_POWN}:${_PGRP}->${_NO}:${_NG}"

    # Write PENDING row to touched CSV
    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
      "$(csv_q "$_P")"    "$(csv_q "$_TYPE")" "$(csv_q "$_PMOD")" \
      "$(csv_q "$_POWN")" "$(csv_q "$_PGRP")" "$(csv_q "$_PAF")" \
      "$(csv_q "$_NM")"   "$(csv_q "$_NO")"   "$(csv_q "$_NG")" \
      '"PENDING"' >>"$_TC"

    if [[ $_DRY -eq 1 ]]; then
      csv_set_result "$_TC" "\"${_P}\"" '"PENDING"' '"DRYRUN"'
      continue
    fi

    # ── APPLY ───────────────────────────────────────────────────────────────
    typeset _RES="OK"

    chmod "$_NM" "$_P" 2>/dev/null || _RES="FAIL_CHMOD"

    if [[ "$_RES" = "OK" ]]; then
      if [[ "$_NO" != "-" && -n "$_NO" && "$_NG" != "-" && -n "$_NG" ]]; then
        chown "${_NO}:${_NG}" "$_P" 2>/dev/null || _RES="FAIL_CHOWN"
      elif [[ "$_NO" != "-" && -n "$_NO" ]]; then
        chown "$_NO" "$_P" 2>/dev/null || _RES="FAIL_CHOWN"
      elif [[ "$_NG" != "-" && -n "$_NG" ]]; then
        chgrp "$_NG" "$_P" 2>/dev/null || _RES="FAIL_CHGRP"
      fi
    fi

    # Post-apply verification
    if [[ "$_RES" = "OK" ]]; then
      typeset _PM2
      _PM2=$(get_octal "$_P")
      if [[ "$_PM2" != "$_NM" ]]; then
        _RES="VERIFY_FAIL"
      fi
    fi

    csv_set_result "$_TC" "\"${_P}\"" '"PENDING"' "\"${_RES}\""
    flog "RESULT: $_P -> $_RES"

    if [[ "$_RES" = "OK" ]]; then
      _RA=$(( _RA + 1 ))
    else
      _RF=$(( _RF + 1 ))
      prog_done
      RED "FAIL[$_RES]: $_P"
    fi

    prog_rem "$_RA" "$_RP" "$_P" "$_RES"

  done <"$_DC"

  prog_done

  if [[ $_DRY -eq 0 ]]; then
    build_rollback "$_TC" "$_RB"
  fi

  printf "\n%s\n" "$SEP"
  if [[ $_DRY -eq 1 ]]; then
    BOLD "DRY-RUN COMPLETE"
    printf "  (Re-run without dry-run flag to apply)\n"
  else
    BOLD "APPLY COMPLETE"
  fi
  printf "  Planned:  %d\n  Applied:  %d\n  Skipped:  %d\n  Failed:   %d\n" \
    "$_RP" "$_RA" "$_RS" "$_RF"
  printf "  Log:      %s\n" "$_LOGFILE"
  printf "  Touched:  %s\n" "$_TC"
  if [[ $_DRY -eq 0 ]]; then
    printf "  Rollback: %s\n" "$_RB"
    printf "  ACL bkp:  %s\n" "$_AD"
    printf "  Verify:   select Verify from menu (option 4)\n"
  fi
  printf "%s\n" "$SEP"

  _LOGFILE=""
  if [[ $_RF -gt 0 ]]; then return 1; fi
  return 0
}

###############################################################################
# SECTION 24 — ROLLBACK EXECUTION
###############################################################################
run_rollback_script() {
  typeset _RB="$1" _DRY="$2"
  if [[ ! -x "$_RB" ]]; then
    die "Rollback script not executable: $_RB"
  fi

  typeset _RBD
  _RBD=$(dirname "$_RB")
  typeset _TS
  _TS=$(date +%Y%m%d_%H%M%S)
  typeset _RLOG="${_RBD}/rollback_run_${_TS}.log"

  printf "\n%s\n" "$SEP"
  if [[ $_DRY -eq 1 ]]; then
    BOLD " ROLLBACK DRY-RUN — no changes will be made"
  else
    BOLD " APPLYING ROLLBACK"
  fi
  printf "%s\n\n" "$SEP"

  if [[ $_DRY -eq 1 ]]; then
    ksh "$_RB" -n 2>&1 | tee "$_RLOG"
  else
    ksh "$_RB" 2>&1 | tee "$_RLOG"
  fi

  printf "\n  Log: %s\n" "$_RLOG"

  # After real rollback: offer immediate verify — pass "rollback" mode
  if [[ $_DRY -eq 0 ]]; then
    typeset _TC
    _TC=$(grep 'TC=' "$_RB" 2>/dev/null | head -1 | sed 's/TC="\(.*\)"/\1/')
    if [[ -n "$_TC" && -r "$_TC" ]]; then
      if confirm "Run post-rollback verify now?"; then
        run_verify "$_TC" "$_RBD" "rollback"
      fi
    fi
  fi
}

run_prefix_rollback() {
  typeset _TC="$1" _PFX="$2" _DRY="$3"
  if [[ ! -r "$_TC" ]]; then die "Cannot read touched CSV: $_TC"; fi

  typeset _RBD
  _RBD=$(dirname "$_TC")
  typeset _TS
  _TS=$(date +%Y%m%d_%H%M%S)
  typeset _RLOG="${_RBD}/rollback_prefix_${_TS}.log"

  printf "\n%s\n" "$SEP"
  printf " Prefix rollback\n"
  printf " Touched CSV: %s\n" "$_TC"
  printf " Prefix:      %s\n" "$_PFX"
  if [[ $_DRY -eq 1 ]]; then
    printf " Mode:        DRY-RUN\n"
  else
    printf " Mode:        REAL\n"
  fi
  printf "%s\n" "$SEP"
  confirm "Proceed?" || return 1

  typeset _FAIL=0 _DONE=0

  {
    tail -n +2 "$_TC" | \
    while IFS=',' read _QP _QT _QOM _QOO _QOG _QOA _QNM _QNO _QNG _QR; do
      typeset _P _OM _OO _OG _OA
      _P=$(csv_uq  "$_QP")
      _OM=$(csv_uq "$_QOM")
      _OO=$(csv_uq "$_QOO")
      _OG=$(csv_uq "$_QOG")
      _OA=$(csv_uq "$_QOA")

      [[ -z "$_P" ]] && continue

      case "$_P" in
        "$_PFX"|"$_PFX"/*) : ;;
        *) continue ;;
      esac

      if [[ -L "$_P" ]]; then printf "SKIP symlink: %s\n" "$_P"; continue; fi
      if [[ ! -e "$_P" ]]; then printf "MISSING: %s\n" "$_P"; continue; fi

      _DONE=$(( _DONE + 1 ))

      if [[ $_DRY -eq 1 ]]; then
        printf "DRYRUN: chmod %s '%s'\n" "$_OM" "$_P"
        if [[ -n "$_OO" && "$_OO" != "-" ]]; then
          printf "DRYRUN: chown %s '%s'\n" "$_OO" "$_P"
        fi
        if command -v aclput >/dev/null 2>&1 && \
           [[ -n "$_OA" && -s "$_OA" ]]; then
          printf "DRYRUN: aclput -i '%s' '%s'\n" "$_OA" "$_P"
        fi
        continue
      fi

      if [[ -n "$_OM" && "$_OM" != "-" ]]; then
        printf "chmod %s '%s' ... " "$_OM" "$_P"
        if chmod "$_OM" "$_P" 2>/dev/null; then
          printf "OK\n"
        else
          printf "FAIL\n"
          _FAIL=$(( _FAIL + 1 ))
        fi
      fi

      if [[ -n "$_OO" && "$_OO" != "-" && -n "$_OG" && "$_OG" != "-" ]]; then
        chown "${_OO}:${_OG}" "$_P" 2>/dev/null || _FAIL=$(( _FAIL + 1 ))
      elif [[ -n "$_OO" && "$_OO" != "-" ]]; then
        chown "$_OO" "$_P" 2>/dev/null || _FAIL=$(( _FAIL + 1 ))
      elif [[ -n "$_OG" && "$_OG" != "-" ]]; then
        chgrp "$_OG" "$_P" 2>/dev/null || _FAIL=$(( _FAIL + 1 ))
      fi

      if command -v aclput >/dev/null 2>&1 && \
         [[ -n "$_OA" && -s "$_OA" ]]; then
        aclput -i "$_OA" "$_P" 2>/dev/null || _FAIL=$(( _FAIL + 1 ))
      fi
    done

    printf "\n%s\n" "$SEP"
    printf " Prefix rollback complete.\n"
    printf "  Items processed: %d\n" "$_DONE"
    printf "  Failures:        %d\n" "$_FAIL"
    printf "  Log:             %s\n" "$_RLOG"
    printf "%s\n" "$SEP"
  } 2>&1 | tee "$_RLOG"

  if [[ $_DRY -eq 0 ]]; then
    if confirm "Run post-rollback verify now?"; then
      run_verify "$_TC" "$_RBD" "rollback"
    fi
  fi
}

###############################################################################
# SECTION 25 — VERIFY
# mode parameter: "remediation" (default) or "rollback"
# remediation: compares actual state vs NEW_MODE/NEW_OWNER/NEW_GROUP (col 7/8/9)
# rollback:    compares actual state vs OLD_MODE/OLD_OWNER/OLD_GROUP (col 3/4/5)
###############################################################################
run_verify() {
  typeset _TC="$1" _OD="$2"
  typeset _VMODE="${3:-remediation}"   # "remediation" or "rollback"

  if [[ ! -r "$_TC" ]]; then die "Cannot read touched CSV: $_TC"; fi

  typeset _TS
  _TS=$(date +%Y%m%d_%H%M%S)
  typeset _RPT="${_OD}/verify_report_${_TS}.csv"

  printf "FULL_PATH,INTENDED_MODE,ACTUAL_MODE," >"$_RPT"
  printf "INTENDED_OWNER,ACTUAL_OWNER," >>"$_RPT"
  printf "INTENDED_GROUP,ACTUAL_GROUP,RESULT\n" >>"$_RPT"

  typeset _PASS=0 _FAIL=0 _MISS=0

  tail -n +2 "$_TC" | \
  while IFS=',' read _QP _QT _QOM _QOO _QOG _QOA _QNM _QNO _QNG _QR; do
    typeset _P _IM _IO _IG
    _P=$(csv_uq "$_QP")
    [[ -z "$_P" ]] && continue

    # Choose intended state based on verify mode
    if [[ "$_VMODE" = "rollback" ]]; then
      # After rollback we expect OLD state to be restored
      _IM=$(csv_uq "$_QOM")   # OLD_MODE   col 3
      _IO=$(csv_uq "$_QOO")   # OLD_OWNER  col 4
      _IG=$(csv_uq "$_QOG")   # OLD_GROUP  col 5
    else
      # After remediation we expect NEW state to be applied
      _IM=$(csv_uq "$_QNM")   # NEW_MODE   col 7
      _IO=$(csv_uq "$_QNO")   # NEW_OWNER  col 8
      _IG=$(csv_uq "$_QNG")   # NEW_GROUP  col 9
    fi

    if [[ ! -e "$_P" && ! -L "$_P" ]]; then
      printf "%s,MISSING,MISSING,MISSING,MISSING,MISSING,MISSING,FAIL\n" \
        "$_P" >>"$_RPT"
      _MISS=$(( _MISS + 1 ))
      continue
    fi

    typeset _AM _AOG _AO _AG
    _AM=$(get_octal "$_P")
    _AOG=$(get_og "$_P")
    _AO=$(printf "%s" "$_AOG" | cut -d: -f1)
    _AG=$(printf "%s" "$_AOG" | cut -d: -f2)

    typeset _OK=1
    if [[ -n "$_IM" && "$_IM" != "-" && "$_AM" != "$_IM" ]]; then _OK=0; fi
    if [[ -n "$_IO" && "$_IO" != "-" && "$_AO" != "$_IO" ]]; then _OK=0; fi
    if [[ -n "$_IG" && "$_IG" != "-" && "$_AG" != "$_IG" ]]; then _OK=0; fi

    typeset _RES="PASS"
    if [[ $_OK -eq 0 ]]; then _RES="FAIL"; fi

    printf "%s,%s,%s,%s,%s,%s,%s,%s\n" \
      "$(csv_q "$_P")"  "$(csv_q "$_IM")" "$(csv_q "$_AM")" \
      "$(csv_q "$_IO")" "$(csv_q "$_AO")" \
      "$(csv_q "$_IG")" "$(csv_q "$_AG")" "$_RES" >>"$_RPT"

    if [[ $_OK -eq 1 ]]; then
      _PASS=$(( _PASS + 1 ))
    else
      _FAIL=$(( _FAIL + 1 ))
    fi
  done

  printf "\n%s\n" "$SEP"
  printf " Verify complete"
  if [[ "$_VMODE" = "rollback" ]]; then
    printf " (post-rollback — checking restored state)\n"
  else
    printf " (post-remediation — checking applied state)\n"
  fi
  printf "  PASS:    %d\n" "$_PASS"
  printf "  FAIL:    %d\n" "$_FAIL"
  printf "  MISSING: %d\n" "$_MISS"
  printf "  Report:  %s\n" "$_RPT"
  printf "%s\n" "$SEP"

  if [[ $_FAIL -gt 0 || $_MISS -gt 0 ]]; then
    YELLOW "WARNING: Some items did not match intended state."
    printf "Review: %s\n" "$_RPT"
  else
    GREEN "All items verified PASS."
  fi
}

###############################################################################
# SECTION 26 — MENU SELECTORS
# ksh88-safe: numbered variables + eval for all lists (NO typeset -a)
# Maximum 20 items per selector (sufficient for all real-world use cases)
###############################################################################
_SEL_RUN=""
select_run() {
  _SEL_RUN=""
  typeset _I=0
  typeset _V0=""  _V1=""  _V2=""  _V3=""  _V4=""  _V5=""  _V6=""  _V7=""  _V8=""  _V9=""
  typeset _V10="" _V11="" _V12="" _V13="" _V14="" _V15="" _V16="" _V17="" _V18="" _V19=""

  for _RD in "${BASE_OUT}"/discovery_*; do
    [[ -d "$_RD" ]] || continue
    eval "_V${_I}=\${_RD}"
    _I=$(( _I + 1 ))
    [[ $_I -ge 20 ]] && break
  done

  if [[ $_I -eq 0 ]]; then
    YELLOW "No discovery runs found under $BASE_OUT"
    return 1
  fi

  printf "\n%s\n" "$SEP"
  BOLD "Select a discovery run"
  printf "%s\n" "$SEP2"

  typeset _J=0
  while [[ $_J -lt $_I ]]; do
    typeset _RD
    eval "_RD=\${_V${_J}}"
    typeset _META="${_RD}/run.meta"
    if [[ -r "$_META" ]]; then
      typeset _RTS _RM _RTOT _RHI
      _RTS=$(awk  -F= '/^CREATED=/{sub(/^CREATED=/,"");print;exit}' "$_META")
      _RM=$(awk   -F= '/^MODE=/{sub(/^MODE=/,"");print;exit}'       "$_META")
      _RTOT=$(awk -F= '/^TOTAL=/{sub(/^TOTAL=/,"");print;exit}'     "$_META")
      _RHI=$(awk  -F= '/^HIGH=/{sub(/^HIGH=/,"");print;exit}'       "$_META")
      printf "[%d] %-38s  mode=%-4s  items=%-5s  high=%-4s  %s\n" \
        "$(( _J + 1 ))" "$(basename "$_RD")" \
        "$_RM" "$_RTOT" "$_RHI" "$_RTS"
    else
      printf "[%d] %s\n" "$(( _J + 1 ))" "$(basename "$_RD")"
    fi
    _J=$(( _J + 1 ))
  done

  ask _N "\nEnter number (0 to cancel): "
  is_int "$_N" || { warn "Invalid selection"; return 1; }
  [[ "$_N" -eq 0 ]] && return 1
  [[ "$_N" -gt $_I ]] && { warn "Out of range"; return 1; }

  eval "_SEL_RUN=\${_V$(( _N - 1 ))}"
  return 0
}

_SEL_FILE=""
select_file() {
  typeset _PROMPT="$1"; shift
  _SEL_FILE=""
  typeset _I=0
  typeset _V0=""  _V1=""  _V2=""  _V3=""  _V4=""  _V5=""  _V6=""  _V7=""  _V8=""  _V9=""
  typeset _V10="" _V11="" _V12="" _V13="" _V14="" _V15="" _V16="" _V17="" _V18="" _V19=""

  for _F in "$@"; do
    [[ -z "$_F" || ! -f "$_F" ]] && continue
    eval "_V${_I}=\${_F}"
    _I=$(( _I + 1 ))
    [[ $_I -ge 20 ]] && break
  done

  if [[ $_I -eq 0 ]]; then
    warn "No files found"
    return 1
  fi

  printf "\n%s\n%s\n%s\n" "$SEP" "$_PROMPT" "$SEP2"
  typeset _J=0
  while [[ $_J -lt $_I ]]; do
    typeset _FF
    eval "_FF=\${_V${_J}}"
    printf "[%d] %s\n" "$(( _J + 1 ))" "$_FF"
    _J=$(( _J + 1 ))
  done

  ask _N "Enter number (0 to cancel): "
  is_int "$_N" || { warn "Invalid"; return 1; }
  [[ "$_N" -eq 0 ]] && return 1
  [[ "$_N" -gt $_I ]] && { warn "Out of range"; return 1; }

  eval "_SEL_FILE=\${_V$(( _N - 1 ))}"
  return 0
}

_SEL_DIR=""
select_dir_glob() {
  typeset _PROMPT="$1" _GLOB="$2"
  _SEL_DIR=""
  typeset _I=0
  typeset _V0=""  _V1=""  _V2=""  _V3=""  _V4=""  _V5=""  _V6=""  _V7=""  _V8=""  _V9=""
  typeset _V10="" _V11="" _V12="" _V13="" _V14="" _V15="" _V16="" _V17="" _V18="" _V19=""

  for _D in $_GLOB; do
    [[ -d "$_D" ]] || continue
    eval "_V${_I}=\${_D}"
    _I=$(( _I + 1 ))
    [[ $_I -ge 20 ]] && break
  done

  if [[ $_I -eq 0 ]]; then
    warn "No directories found"
    return 1
  fi

  printf "\n%s\n%s\n%s\n" "$SEP" "$_PROMPT" "$SEP2"
  typeset _J=0
  while [[ $_J -lt $_I ]]; do
    typeset _DD
    eval "_DD=\${_V${_J}}"
    printf "[%d] %s\n" "$(( _J + 1 ))" "$_DD"
    _J=$(( _J + 1 ))
  done

  ask _N "Enter number (0 to cancel): "
  is_int "$_N" || { warn "Invalid"; return 1; }
  [[ "$_N" -eq 0 ]] && return 1
  [[ "$_N" -gt $_I ]] && { warn "Out of range"; return 1; }

  eval "_SEL_DIR=\${_V$(( _N - 1 ))}"
  return 0
}

###############################################################################
# SECTION 27 — MENU: DISCOVERY
###############################################################################
menu_discovery() {
  printf "\n%s\n" "$SEP"
  BOLD " DISCOVERY"
  printf "%s\n" "$SEP"

  # Collect scan roots — mandatory, loop until valid input given
  typeset _ROOTS=""
  while [[ -z "$_ROOTS" ]]; do
    printf "\nEnter one or more paths to scan (space-separated).\n"
    printf "Examples: /tmp   /download   /cdirect   /download /cdirect\n"
    if [[ -n "$DEFAULT_ROOTS" ]]; then
      ask _ROOTS "Press ENTER for saved default [$DEFAULT_ROOTS]: "
      [[ -z "$_ROOTS" ]] && _ROOTS="$DEFAULT_ROOTS"
    else
      ask _ROOTS "Scan roots: "
    fi
    if [[ -z "$_ROOTS" ]]; then
      YELLOW "At least one path is required."
      continue
    fi
    # Validate each root
    typeset _BAD=0
    for _R in $_ROOTS; do
      if [[ ! -e "$_R" ]]; then
        YELLOW "WARNING: path not found on this host: $_R"
        _BAD=1
      fi
    done
    if [[ $_BAD -eq 1 ]]; then
      confirm "One or more paths not found. Continue anyway?" || {
        _ROOTS=""
        continue
      }
    fi
  done

  printf "\nPermission mode:\n"
  printf "  1) WW   — world-writable (includes 666/777/1777)\n"
  printf "  2) 777  — exact 0777 only\n"
  printf "  3) 777D — exact 0777 + 1777 directories\n"
  ask _MC "Choice [default WW]: "
  typeset _SM
  case "$_MC" in
    2) _SM="777"  ;;
    3) _SM="777D" ;;
    *) _SM="WW"   ;;
  esac

  printf "\nCandidate enumeration:\n"
  printf "  1) AUTO — auto-detect (recommended)\n"
  printf "  2) STAT — enumerate all, filter via stat\n"
  printf "  3) FIND — use find -perm -002 (fast; AIX find must support it)\n"
  ask _CC "Choice [default AUTO]: "
  typeset _CM
  case "$_CC" in
    2) _CM="STAT" ;;
    3) _CM="FIND" ;;
    *) _CM="AUTO" ;;
  esac

  # /tmp-specific prompt
  typeset _ET=$EXCLUDE_TMP_ROOT
  for _R in $_ROOTS; do
    if [[ "$_R" = "/tmp" ]]; then
      if confirm "Include /tmp itself as a finding?"; then
        _ET=0
      else
        _ET=1
      fi
      break
    fi
  done

  typeset _OUT="$BASE_OUT"
  ask _TOUT "Output base dir [default: $BASE_OUT]: "
  if [[ -n "$_TOUT" ]]; then
    mkdir -p "$_TOUT" 2>/dev/null || { warn "Cannot create: $_TOUT"; return; }
    BASE_OUT="$_TOUT"
    _OUT="$_TOUT"
  fi

  printf "\n%s\n" "$SEP"
  printf " About to scan:\n"
  printf "   Roots:       %s\n" "$_ROOTS"
  printf "   Perm mode:   %s\n" "$_SM"
  printf "   Candidate:   %s\n" "$_CM"
  if [[ $_ET -eq 1 ]]; then
    printf "   Excl /tmp:   YES\n"
  else
    printf "   Excl /tmp:   NO\n"
  fi
  printf "   Output:      %s\n" "$_OUT"
  printf "%s\n" "$SEP"

  confirm "Proceed with discovery?" || return

  run_discovery "$_ROOTS" "$_SM" "$_CM" "$_ET"
  pause
}

###############################################################################
# SECTION 28 — MENU: REMEDIATION
###############################################################################
menu_remediation() {
  printf "\n%s\n" "$SEP"
  BOLD " REMEDIATION"
  printf "%s\n" "$SEP"

  select_run || return
  typeset _RUN="$_SEL_RUN"

  # Select discovery CSV
  typeset _DFILES
  _DFILES=$(ls -1 "${_RUN}"/discovery_perm_*.csv 2>/dev/null)
  set -- $_DFILES
  select_file "Select discovery CSV" "$@" || return
  typeset _DC="$_SEL_FILE"

  # Optionally select hints CSV
  typeset _HC=""
  typeset _HFILES
  _HFILES=$(ls -1 "${_RUN}"/hints_perm_*.csv 2>/dev/null)
  if [[ -n "$_HFILES" ]]; then
    if confirm "Use hints CSV for suggested modes / risk filter?"; then
      set -- $_HFILES
      if select_file "Select hints CSV" "$@"; then
        _HC="$_SEL_FILE"
      fi
    fi
  fi

  # Scope selection
  printf "\nRemediation scope:\n"
  printf "  1) All items in CSV\n"
  printf "  2) Prefix / directory\n"
  printf "  3) Single specific path\n"
  printf "  4) Risk level filter (requires hints CSV)\n"
  ask _SC "Choice: "

  typeset _TP="" _TD="" _FL=""
  case "$_SC" in
    1) : ;;
    2) ask _TD "Directory prefix (e.g. /tmp/mydir): "
       [[ -z "$_TD" ]] && { warn "Empty prefix"; return; } ;;
    3) ask _TP "Full path: "
       [[ -z "$_TP" ]] && { warn "Empty path"; return; } ;;
    4) if [[ -z "$_HC" ]]; then warn "Hints CSV not selected"; return; fi
       ask _FL "Risk level (LOW|MEDIUM|HIGH|ALL): "
       _FL=$(printf "%s" "$_FL" | tr '[:lower:]' '[:upper:]') ;;
    *) warn "Invalid scope choice"; return ;;
  esac

  # Mode/owner/group source
  printf "\nTarget mode/owner/group source:\n"
  printf "  1) Use hints suggestions (requires hints CSV)\n"
  printf "  2) Override mode only\n"
  printf "  3) Override mode + owner + group\n"
  ask _MD "Choice: "

  typeset _OM="" _OO="" _OG=""
  case "$_MD" in
    1) if [[ -z "$_HC" ]]; then warn "Hints CSV not selected"; return; fi ;;
    2) ask _OM "Mode (e.g. 0750 or 2770): "
       [[ -z "$_OM" ]] && { warn "Empty mode"; return; } ;;
    3) ask _OM "Mode: "
       [[ -z "$_OM" ]] && { warn "Empty mode"; return; }
       ask _OO "Owner (enter - to keep existing): "
       ask _OG "Group (enter - to keep existing): "
       [[ -z "$_OO" ]] && _OO="-"
       [[ -z "$_OG" ]] && _OG="-" ;;
    *) warn "Invalid choice"; return ;;
  esac

  typeset _TS
  _TS=$(date +%Y%m%d_%H%M%S)
  typeset _OD="${_RUN}/remediation_${_TS}"

  # Mandatory dry-run first
  printf "\n%s\n" "$SEP"
  YELLOW " MANDATORY DRY-RUN (no changes will be made)"
  printf "%s\n" "$SEP"
  confirm "Run dry-run?" || return

  run_remediation "$_DC" "$_HC" "$_OD" \
    "$_TP" "$_TD" "$_FL" "$_OM" "$_OO" "$_OG" 1

  printf "\nDry-run complete. Review the [PLAN] lines above.\n"
  if confirm "Apply changes now?"; then
    run_remediation "$_DC" "$_HC" "$_OD" \
      "$_TP" "$_TD" "$_FL" "$_OM" "$_OO" "$_OG" 0
  fi
  pause
}

###############################################################################
# SECTION 29 — MENU: ROLLBACK
###############################################################################
menu_rollback() {
  printf "\n%s\n" "$SEP"
  BOLD " ROLLBACK"
  printf "%s\n" "$SEP"

  select_run || return
  typeset _RUN="$_SEL_RUN"

  typeset _RBFILES
  _RBFILES=$(find "$_RUN" \
    -name 'rollback_permissions_*.sh' -type f -print 2>/dev/null | sort)
  set -- $_RBFILES
  select_file "Select rollback script" "$@" || return
  typeset _RB="$_SEL_FILE"

  printf "\nRollback scope:\n"
  printf "  1) Full rollback (all items in the script)\n"
  printf "  2) Prefix-filtered rollback (subset by path prefix)\n"
  ask _SCOPE "Choice: "

  case "$_SCOPE" in
    1)
      printf "\n  1) Dry-run (show what would happen)\n"
      printf "  2) Real rollback (apply changes)\n"
      ask _CH "Choice: "
      typeset _DRY=1
      [[ "$_CH" = "2" ]] && _DRY=0
      if [[ $_DRY -eq 0 ]]; then
        confirm_yes "Apply FULL rollback?" || { pause; return; }
      fi
      run_rollback_script "$_RB" "$_DRY"
      pause
      ;;
    2)
      typeset _RBD
      _RBD=$(dirname "$_RB")
      typeset _TC
      _TC=$(ls -1t "${_RBD}"/remediate_touched_*.csv 2>/dev/null | head -1)
      if [[ -z "$_TC" ]]; then
        warn "No touched CSV found in $_RBD"
        pause
        return
      fi
      ask _PFX "Enter prefix to rollback (e.g. /tmp/mydir): "
      if [[ -z "$_PFX" ]]; then warn "Empty prefix"; return; fi
      printf "\n  1) Dry-run\n  2) Real rollback\n"
      ask _CH "Choice: "
      typeset _DRY=1
      [[ "$_CH" = "2" ]] && _DRY=0
      run_prefix_rollback "$_TC" "$_PFX" "$_DRY"
      pause
      ;;
    *)
      warn "Invalid scope choice"
      ;;
  esac
}

###############################################################################
# SECTION 30 — MENU: VERIFY
###############################################################################
menu_verify() {
  printf "\n%s\n" "$SEP"
  BOLD " VERIFY"
  printf "%s\n" "$SEP"

  select_run || return
  typeset _RUN="$_SEL_RUN"

  select_dir_glob "Select remediation directory" "${_RUN}/remediation_*" || return
  typeset _RD="$_SEL_DIR"

  typeset _TC
  _TC=$(ls -1t "${_RD}"/remediate_touched_*.csv 2>/dev/null | head -1)
  if [[ -z "$_TC" ]]; then
    warn "No touched CSV found in $_RD"
    pause
    return
  fi

  printf "\nUsing touched CSV: %s\n" "$_TC"
  confirm "Run verify?" || return

  run_verify "$_TC" "$_RD"
  pause
}

###############################################################################
# SECTION 31 — MENU: REPORTS
###############################################################################
menu_reports() {
  printf "\n%s\n" "$SEP"
  BOLD " REPORTS"
  printf "%s\n" "$SEP"

  select_run || return
  typeset _RUN="$_SEL_RUN"

  printf "\n"
  printf "  1) Summary TXT\n"
  printf "  2) Discovery CSV preview (first 25 rows)\n"
  printf "  3) Hints CSV preview (first 25 rows)\n"
  printf "  4) Risk breakdown from hints\n"
  printf "  5) List remediation directories\n"
  printf "  6) Latest verify report\n"
  ask _CH "Choice: "

  case "$_CH" in
    1)
      typeset _SF
      _SF=$(ls -1t "${_RUN}"/summary_perm_*.txt 2>/dev/null | head -1)
      if [[ -z "$_SF" ]]; then warn "No summary TXT found"; pause; return; fi
      cat "$_SF"
      ;;
    2)
      typeset _DF
      _DF=$(ls -1 "${_RUN}"/discovery_perm_*.csv 2>/dev/null)
      set -- $_DF
      select_file "Select discovery CSV" "$@" || return
      head -26 "$_SEL_FILE"
      printf "\nData rows: %s\n" \
        "$(tail -n +2 "$_SEL_FILE" | wc -l | awk '{print $1+0}')"
      ;;
    3)
      typeset _HF
      _HF=$(ls -1 "${_RUN}"/hints_perm_*.csv 2>/dev/null)
      set -- $_HF
      select_file "Select hints CSV" "$@" || return
      head -26 "$_SEL_FILE"
      ;;
    4)
      typeset _HF
      _HF=$(ls -1 "${_RUN}"/hints_perm_*.csv 2>/dev/null)
      set -- $_HF
      select_file "Select hints CSV" "$@" || return
      printf "\nRisk breakdown:\n"
      awk -F',' 'NR>1 { gsub(/"/, "", $3); cnt[$3]++ }
        END { for (r in cnt) printf "  %-8s %d\n", r, cnt[r] }' \
        "$_SEL_FILE" | sort
      ;;
    5)
      typeset _RDIRS
      _RDIRS=$(ls -1d "${_RUN}"/remediation_* 2>/dev/null)
      if [[ -z "$_RDIRS" ]]; then
        printf "No remediation directories found.\n"
      else
        for _D in $_RDIRS; do
          typeset _TC
          _TC=$(ls -1t "${_D}"/remediate_touched_*.csv 2>/dev/null | head -1)
          typeset _CNT="?"
          if [[ -n "$_TC" ]]; then
            _CNT=$(tail -n +2 "$_TC" | wc -l | awk '{print $1+0}')
          fi
          printf "  %s  (touched=%s)\n" "$_D" "$_CNT"
        done
      fi
      ;;
    6)
      typeset _VR
      _VR=$(find "$_RUN" -name 'verify_report_*.csv' \
        -type f -print 2>/dev/null | sort | tail -1)
      if [[ -z "$_VR" ]]; then
        printf "No verify report found.\n"
      else
        cat "$_VR"
      fi
      ;;
    *)
      warn "Invalid choice"
      ;;
  esac
  pause
}

###############################################################################
# SECTION 32 — MENU: SETTINGS
###############################################################################
menu_settings() {
  while :; do
    printf "\n%s\n" "$SEP"
    BOLD " SETTINGS"
    printf "%s\n" "$SEP"
    printf "  BASE_OUT             = %s\n" "$BASE_OUT"
    if [[ -n "$DEFAULT_ROOTS" ]]; then
      printf "  DEFAULT_ROOTS        = %s\n" "$DEFAULT_ROOTS"
    else
      printf "  DEFAULT_ROOTS        = (prompt each time)\n"
    fi
    printf "  DEFAULT_MODE         = %s\n" "$DEFAULT_MODE"
    printf "  DEFAULT_CAND         = %s\n" "$DEFAULT_CAND"
    printf "  RECENT_DAYS          = %s\n" "$RECENT_DAYS"
    printf "  LARGE_MB             = %s\n" "$LARGE_MB"
    printf "  HIGH_FILES           = %s\n" "$HIGH_FILES"
    printf "  EXCLUDE_TMP_ROOT     = %s\n" "$EXCLUDE_TMP_ROOT"
    printf "  SKIP_ACL             = %s\n" "$SKIP_ACL"
    printf "%s\n" "$SEP2"
    printf "  Performance tuning:\n"
    printf "  CHUNK_SIZE           = %s\n" "$CHUNK_SIZE"
    printf "  PROG_INTERVAL        = %s\n" "$PROG_INTERVAL"
    printf "  SKIP_REC             = %s  (0=full recursive count; 1=fast/ls count or skip)\n" "$SKIP_REC"
    printf "  COUNT_MATCHED_DIRS   = %s  (1=count immediate children of matched dirs)\n" "$COUNT_MATCHED_DIRS"
    printf "  SKIP_DU              = %s\n" "$SKIP_DU"
    printf "  FIND_TIMEOUT         = %s\n" "$FIND_TIMEOUT"
    printf "  RESUME_ENABLED       = %s\n" "$RESUME_ENABLED"
    printf "  MAX_TMP_MB           = %s\n" "$MAX_TMP_MB"
    printf "  LOG_TIMING           = %s\n" "$LOG_TIMING"
    printf "  Config file          = %s\n" "$CONF_FILE"
    printf "%s\n" "$SEP2"
    printf "   1) BASE_OUT           2) DEFAULT_ROOTS      3) DEFAULT_MODE\n"
    printf "   4) DEFAULT_CAND       5) RECENT_DAYS        6) LARGE_MB\n"
    printf "   7) HIGH_FILES         8) Toggle EXCLUDE_TMP_ROOT (%s)\n" \
      "$EXCLUDE_TMP_ROOT"
    printf "   9) Toggle SKIP_ACL (%s)\n" "$SKIP_ACL"
    printf "  10) CHUNK_SIZE        11) PROG_INTERVAL\n"
    printf "  12) Toggle SKIP_REC (%s)  13) Toggle SKIP_DU (%s)\n" \
      "$SKIP_REC" "$SKIP_DU"
    printf "  14) FIND_TIMEOUT      15) Toggle RESUME_ENABLED (%s)\n" \
      "$RESUME_ENABLED"
    printf "  16) MAX_TMP_MB        17) Toggle LOG_TIMING (%s)\n" \
      "$LOG_TIMING"
    printf "  19) Toggle COUNT_MATCHED_DIRS (%s)\n" "$COUNT_MATCHED_DIRS"
    printf "       (1=count immediate children of matched dirs in CSV)\n"
    printf "  18) Save all settings to conf file\n"
    printf "   0) Back\n"
    ask _CH "Choice: "

    case "$_CH" in
      1)
        ask _V "BASE_OUT: "
        if [[ -n "$_V" ]]; then
          if mkdir -p "$_V" 2>/dev/null; then
            BASE_OUT="$_V"
            if confirm "Save BASE_OUT to conf now?"; then save_conf; fi
          else
            warn "Cannot create/access: $_V"
          fi
        fi
        ;;
      2)  ask _V "DEFAULT_ROOTS (blank = always prompt): "
          DEFAULT_ROOTS="$_V" ;;
      3)  ask _V "DEFAULT_MODE (WW|777|777D): "
          case "$_V" in
            WW|777|777D) DEFAULT_MODE="$_V" ;;
            *) warn "Invalid — must be WW, 777, or 777D" ;;
          esac ;;
      4)  ask _V "DEFAULT_CAND (AUTO|STAT|FIND): "
          case "$_V" in
            AUTO|STAT|FIND) DEFAULT_CAND="$_V" ;;
            *) warn "Invalid — must be AUTO, STAT, or FIND" ;;
          esac ;;
      5)  ask _V "RECENT_DAYS: "
          is_int "$_V" && RECENT_DAYS="$_V" || warn "Integer required" ;;
      6)  ask _V "LARGE_MB: "
          is_int "$_V" && LARGE_MB="$_V" || warn "Integer required" ;;
      7)  ask _V "HIGH_FILES: "
          is_int "$_V" && HIGH_FILES="$_V" || warn "Integer required" ;;
      8)  if [[ $EXCLUDE_TMP_ROOT -eq 1 ]]; then EXCLUDE_TMP_ROOT=0
          else EXCLUDE_TMP_ROOT=1; fi
          printf "EXCLUDE_TMP_ROOT = %d\n" "$EXCLUDE_TMP_ROOT" ;;
      9)  if [[ $SKIP_ACL -eq 1 ]]; then SKIP_ACL=0
          else SKIP_ACL=1; fi
          printf "SKIP_ACL = %d\n" "$SKIP_ACL" ;;
      10) ask _V "CHUNK_SIZE (minimum 100): "
          if is_int "$_V" && [[ $_V -ge 100 ]]; then
            CHUNK_SIZE="$_V"
          else
            warn "Integer >= 100 required"
          fi ;;
      11) ask _V "PROG_INTERVAL (minimum 1): "
          if is_int "$_V" && [[ $_V -ge 1 ]]; then
            PROG_INTERVAL="$_V"
          else
            warn "Integer >= 1 required"
          fi ;;
      12) if [[ $SKIP_REC -eq 1 ]]; then SKIP_REC=0
          else SKIP_REC=1; fi
          printf "SKIP_REC = %d\n" "$SKIP_REC" ;;
      13) if [[ $SKIP_DU -eq 1 ]]; then SKIP_DU=0
          else SKIP_DU=1; fi
          printf "SKIP_DU = %d\n" "$SKIP_DU" ;;
      14) ask _V "FIND_TIMEOUT seconds (0 = no limit): "
          is_int "$_V" && FIND_TIMEOUT="$_V" || warn "Integer required" ;;
      15) if [[ $RESUME_ENABLED -eq 1 ]]; then RESUME_ENABLED=0
          else RESUME_ENABLED=1; fi
          printf "RESUME_ENABLED = %d\n" "$RESUME_ENABLED" ;;
      16) ask _V "MAX_TMP_MB (minimum 10): "
          if is_int "$_V" && [[ $_V -ge 10 ]]; then
            MAX_TMP_MB="$_V"
          else
            warn "Integer >= 10 required"
          fi ;;
      17) if [[ $LOG_TIMING -eq 1 ]]; then LOG_TIMING=0
          else LOG_TIMING=1; fi
          printf "LOG_TIMING = %d\n" "$LOG_TIMING" ;;
      19) if [[ $COUNT_MATCHED_DIRS -eq 1 ]]; then COUNT_MATCHED_DIRS=0
          else COUNT_MATCHED_DIRS=1; fi
          printf "COUNT_MATCHED_DIRS = %d\n" "$COUNT_MATCHED_DIRS" ;;
      18) save_conf ;;
      0)  return ;;
      *)  warn "Invalid choice" ;;
    esac
  done
}

###############################################################################
# SECTION 33 — MENU: DIAGNOSTICS
###############################################################################

# 33a — Environment check
diag_env() {
  printf "\n%s\n" "$SEP"
  BOLD " Environment Check"
  printf "%s\n" "$SEP2"
  typeset _OK=1

  typeset _KV
  _KV=$(ksh --version 2>&1 | head -1)
  printf "  ksh:            %s\n" "${_KV:-unknown}"

  if [[ $PERL_OK -eq 1 ]]; then
    typeset _PV
    _PV=$(perl -e 'print $^V' 2>/dev/null)
    GREEN "  perl:           OK ($_PV — fast_stat and ETA enabled)"
  else
    YELLOW "  perl:           NOT FOUND — fallback mode active (slower)"
    _OK=0
  fi

  if command -v aclget >/dev/null 2>&1 && \
     command -v aclput >/dev/null 2>&1; then
    GREEN "  aclget/aclput:  OK — ACL backup and restore enabled"
  else
    YELLOW "  aclget/aclput:  not found — ACL backup/restore disabled"
  fi

  typeset _FP
  _FP=$(find /tmp -xdev -prune -perm -002 -print 2>/dev/null)
  if [[ -n "$_FP" ]]; then
    GREEN "  find -perm:     OK — FIND candidate mode usable"
  else
    YELLOW "  find -perm:     unreliable — STAT candidate mode will be used"
  fi

  typeset _TMPFK _TMPFM
  _TMPFK=$(df -k /tmp 2>/dev/null | awk 'NR==2{print $3}')
  _TMPFK=${_TMPFK:-0}
  _TMPFM=$(( _TMPFK / 1024 ))
  if [[ $_TMPFM -ge 500 ]]; then
    GREEN "  /tmp free:      ${_TMPFM}MB — sufficient for large scans"
  elif [[ $_TMPFM -ge 200 ]]; then
    YELLOW "  /tmp free:      ${_TMPFM}MB — marginal for very large scans"
  else
    RED "  /tmp free:      ${_TMPFM}MB — WARNING: may be insufficient"
    _OK=0
  fi

  if [[ -w "$BASE_OUT" ]]; then
    GREEN "  BASE_OUT:       writable ($BASE_OUT)"
  else
    RED "  BASE_OUT:       NOT WRITABLE ($BASE_OUT)"
    _OK=0
  fi

  if [[ $(id -u) -eq 0 ]]; then
    GREEN "  Running as:     root — all operations enabled"
  else
    YELLOW "  Running as:     $(id -un) — remediation/rollback require root"
  fi

  printf "%s\n" "$SEP2"
  if [[ $_OK -eq 1 ]]; then
    GREEN "  Overall: READY"
  else
    YELLOW "  Overall: WARNINGS — review items above before scanning"
  fi
  printf "%s\n" "$SEP"
}

# 33b — Tail a log file
diag_tail_log() {
  printf "\n%s\n" "$SEP"
  BOLD " Tail Recent Log"
  printf "%s\n" "$SEP2"

  typeset _I=0
  typeset _V0=""  _V1=""  _V2=""  _V3=""  _V4=""  _V5=""  _V6=""  _V7=""  _V8=""  _V9=""
  typeset _V10="" _V11="" _V12="" _V13="" _V14="" _V15="" _V16="" _V17="" _V18="" _V19=""

  for _LF in $(find "$BASE_OUT" -name '*.log' \
      -type f -print 2>/dev/null | sort -r); do
    [[ $_I -ge 20 ]] && break
    eval "_V${_I}=\${_LF}"
    _I=$(( _I + 1 ))
  done

  if [[ $_I -eq 0 ]]; then warn "No log files found under $BASE_OUT"; return; fi

  typeset _J=0
  while [[ $_J -lt $_I ]]; do
    typeset _LF
    eval "_LF=\${_V${_J}}"
    typeset _SZ
    _SZ=$(du -sk "$_LF" 2>/dev/null | awk '{print $1}')
    printf "  [%d] %-65s  %sKB\n" "$(( _J + 1 ))" "$_LF" "$_SZ"
    _J=$(( _J + 1 ))
  done

  ask _N "Enter number (0 to cancel): "
  is_int "$_N" || { warn "Invalid"; return; }
  [[ "$_N" -eq 0 ]] && return
  [[ "$_N" -gt $_I ]] && { warn "Out of range"; return; }

  typeset _CHOSEN
  eval "_CHOSEN=\${_V$(( _N - 1 ))}"

  ask _NL "Lines from end [default 50]: "
  is_int "$_NL" || _NL=50
  [[ "$_NL" -eq 0 ]] && _NL=50

  printf "\n--- tail -%d %s ---\n" "$_NL" "$_CHOSEN"
  tail -"$_NL" "$_CHOSEN"
  printf "\n%s\n" "$SEP"
}

# 33c — Search logs
diag_grep_log() {
  printf "\n%s\n" "$SEP"
  BOLD " Search Logs"
  printf "%s\n" "$SEP2"

  ask _PAT "Pattern (e.g. FAIL, WARN, ERROR, /tmp/path): "
  [[ -z "$_PAT" ]] && { warn "Pattern cannot be empty"; return; }

  printf "  1) Latest discovery log only\n"
  printf "  2) Latest remediation log only\n"
  printf "  3) ALL logs under %s\n" "$BASE_OUT"
  ask _SC "Choice [default 1]: "

  typeset _LOGS
  case "${_SC:-1}" in
    2) _LOGS=$(find "$BASE_OUT" -name 'remediate_*.log' \
         -type f -print 2>/dev/null | sort -r | head -1) ;;
    3) _LOGS=$(find "$BASE_OUT" -name '*.log' \
         -type f -print 2>/dev/null) ;;
    *) _LOGS=$(find "$BASE_OUT" -name 'discover_*.log' \
         -type f -print 2>/dev/null | sort -r | head -1) ;;
  esac

  if [[ -z "$_LOGS" ]]; then warn "No log files found"; return; fi

  typeset _HIT=0
  for _F in $_LOGS; do
    typeset _M
    _M=$(grep -n "$_PAT" "$_F" 2>/dev/null)
    if [[ -n "$_M" ]]; then
      CYAN "==> $_F"
      printf "%s\n" "$_M"
      _HIT=$(( _HIT + 1 ))
    fi
  done
  [[ $_HIT -eq 0 ]] && printf "  (no matches found for '%s')\n" "$_PAT"
  printf "%s\n" "$SEP"
}

# 33d — Show checkpoints
diag_checkpoints() {
  printf "\n%s\n" "$SEP"
  BOLD " Resume Checkpoints"
  printf "%s\n" "$SEP2"
  typeset _FOUND=0
  for _CP in $(find "$BASE_OUT" -name '.scan_checkpoint' \
      -type f -print 2>/dev/null); do
    typeset _LN
    _LN=$(cat "$_CP" 2>/dev/null)
    printf "  Directory: %s\n" "$(dirname "$_CP")"
    printf "  At line:   %s (scan was interrupted here)\n" "$_LN"
    printf "  Resume:    re-run discovery for that run directory\n"
    printf "  Discard:   rm %s\n" "$_CP"
    printf "%s\n" "$SEP2"
    _FOUND=$(( _FOUND + 1 ))
  done
  [[ $_FOUND -eq 0 ]] && printf "  No active checkpoints — no interrupted scans.\n"
  printf "%s\n" "$SEP"
}

# 33e — Clear a checkpoint
diag_clear_ckpt() {
  printf "\n%s\n" "$SEP"
  BOLD " Clear Checkpoint"
  printf "%s\n" "$SEP2"

  typeset _I=0
  typeset _V0="" _V1="" _V2="" _V3="" _V4=""
  typeset _V5="" _V6="" _V7="" _V8="" _V9=""

  for _CP in $(find "$BASE_OUT" -name '.scan_checkpoint' \
      -type f -print 2>/dev/null); do
    eval "_V${_I}=\${_CP}"
    _I=$(( _I + 1 ))
    [[ $_I -ge 10 ]] && break
  done

  if [[ $_I -eq 0 ]]; then
    printf "  No checkpoints found.\n%s\n" "$SEP"
    return
  fi

  typeset _J=0
  while [[ $_J -lt $_I ]]; do
    typeset _CP
    eval "_CP=\${_V${_J}}"
    printf "  [%d] %s  (line %s)\n" \
      "$(( _J + 1 ))" "$(dirname "$_CP")" "$(cat "$_CP" 2>/dev/null)"
    _J=$(( _J + 1 ))
  done

  ask _N "Number to clear (0 to cancel): "
  is_int "$_N" || { warn "Invalid"; return; }
  [[ "$_N" -eq 0 ]] && return
  [[ "$_N" -gt $_I ]] && { warn "Out of range"; return; }

  typeset _CHOSEN
  eval "_CHOSEN=\${_V$(( _N - 1 ))}"

  if confirm "Delete checkpoint: $_CHOSEN?"; then
    if rm -f "$_CHOSEN"; then
      GREEN "  Checkpoint cleared successfully."
    else
      RED "  Failed to remove: $_CHOSEN"
    fi
  fi
  printf "%s\n" "$SEP"
}

# 33f — Validate CSV
diag_validate_csv() {
  printf "\n%s\n" "$SEP"
  BOLD " Validate CSV Integrity"
  printf "%s\n" "$SEP2"

  select_run || return
  typeset _RUN="$_SEL_RUN"

  printf "  1) Discovery CSV\n  2) Hints CSV\n  3) Touched (remediation) CSV\n"
  ask _CH "Choice: "

  typeset _GLOB
  case "$_CH" in
    1) _GLOB=$(ls -1 "${_RUN}"/discovery_perm_*.csv 2>/dev/null) ;;
    2) _GLOB=$(ls -1 "${_RUN}"/hints_perm_*.csv 2>/dev/null) ;;
    3) _GLOB=$(find "$_RUN" -name 'remediate_touched_*.csv' \
         -type f -print 2>/dev/null | sort -r | head -5) ;;
    *) warn "Invalid choice"; return ;;
  esac

  set -- $_GLOB
  select_file "Select CSV to validate" "$@" || return
  typeset _F="$_SEL_FILE"

  printf "\n--- Validating: %s ---\n" "$_F"

  typeset _TL _DR _EC
  _TL=$(wc -l <"$_F" | awk '{print $1+0}')
  _DR=$(( _TL - 1 ))
  _EC=$(head -1 "$_F" | awk -F',' '{print NF}')

  printf "  Total lines:      %d\n" "$_TL"
  printf "  Data rows:        %d\n" "$_DR"
  printf "  Expected columns: %d\n" "$_EC"

  typeset _BAD
  _BAD=$(awk -F',' -v ec="$_EC" \
    'NR>1 && NF!=ec {print NR ": " NF " cols: " $0}' "$_F" | head -10)

  if [[ -z "$_BAD" ]]; then
    GREEN "  Column count: ALL rows correct"
  else
    RED "  Column count: MALFORMED rows detected (first 10):"
    printf "%s\n" "$_BAD"
  fi

  if [[ "$_CH" = "3" ]]; then
    printf "  Result breakdown:\n"
    awk -F',' 'NR>1 { gsub(/"/, "", $10); cnt[$10]++ }
      END { for (r in cnt) printf "    %-15s %d\n", r, cnt[r] }' \
      "$_F" | sort
  fi

  typeset _SZ
  _SZ=$(du -sk "$_F" 2>/dev/null | awk '{print $1}')
  printf "  File size:        %s KB\n" "$_SZ"
  printf "%s\n" "$SEP"
}

# 33g — Rollback integrity
diag_rollback_integrity() {
  printf "\n%s\n" "$SEP"
  BOLD " Rollback Script Integrity"
  printf "%s\n" "$SEP2"

  select_run || return
  typeset _RUN="$_SEL_RUN"

  typeset _RBF
  _RBF=$(find "$_RUN" -name 'rollback_permissions_*.sh' \
    -type f -print 2>/dev/null | sort)
  set -- $_RBF
  select_file "Select rollback script" "$@" || return
  typeset _RB="$_SEL_FILE"

  printf "\nChecking: %s\n%s\n" "$_RB" "$SEP2"

  if [[ -x "$_RB" ]]; then
    GREEN "  Executable:     YES"
  else
    RED "  Executable:     NO — run: chmod 700 '$_RB'"
  fi

  typeset _SE
  _SE=$(ksh -n "$_RB" 2>&1)
  if [[ -z "$_SE" ]]; then
    GREEN "  ksh syntax:     OK"
  else
    RED "  ksh syntax:     ERRORS detected:"
    printf "    %s\n" "$_SE"
  fi

  typeset _TC
  _TC=$(grep 'TC=' "$_RB" 2>/dev/null | head -1 | sed 's/TC="\(.*\)"/\1/')
  if [[ -n "$_TC" && -r "$_TC" ]]; then
    typeset _NR
    _NR=$(tail -n +2 "$_TC" | wc -l | awk '{print $1+0}')
    GREEN "  Touched CSV:    EXISTS ($_NR items) — $_TC"
  else
    RED "  Touched CSV:    MISSING — $_TC"
    RED "  WARNING: rollback cannot run without its touched CSV"
  fi

  typeset _RBD
  _RBD=$(dirname "$_RB")
  typeset _ADIR
  _ADIR=$(ls -1d "${_RBD}"/acl_backup_* 2>/dev/null | head -1)
  if [[ -n "$_ADIR" && -d "$_ADIR" ]]; then
    typeset _AC
    _AC=$(ls -1 "$_ADIR" 2>/dev/null | wc -l | awk '{print $1+0}')
    GREEN "  ACL backup:     EXISTS ($_AC files) — $_ADIR"
  else
    YELLOW "  ACL backup:     not found (OK if no ACL objects were remediated)"
  fi

  printf "%s\n" "$SEP"
}

# 33h — Disk usage
diag_disk_usage() {
  printf "\n%s\n" "$SEP"
  BOLD " Output Disk Usage"
  printf "%s\n" "$SEP2"

  typeset _TOT=0
  for _D in "${BASE_OUT}"/discovery_*; do
    [[ -d "$_D" ]] || continue
    typeset _SZ
    _SZ=$(du -sk "$_D" 2>/dev/null | awk '{print $1}')
    _SZ=${_SZ:-0}
    _TOT=$(( _TOT + _SZ ))
    printf "  %6d KB   %s\n" "$_SZ" "$(basename "$_D")"
  done

  printf "%s\n" "$SEP2"
  printf "  Total used:  %d KB  (%d MB)\n" "$_TOT" "$(( _TOT / 1024 ))"
  typeset _FK
  _FK=$(df -k "$BASE_OUT" 2>/dev/null | awk 'NR==2{print $3}')
  _FK=${_FK:-0}
  printf "  Free on %s:  %d KB  (%d MB)\n" \
    "$BASE_OUT" "$_FK" "$(( _FK / 1024 ))"
  printf "%s\n" "$SEP"
}

# 33i — Purge old runs
diag_purge_runs() {
  printf "\n%s\n" "$SEP"
  BOLD " Purge Old Run Directories"
  printf "%s\n" "$SEP2"
  YELLOW "  WARNING: Permanently deletes run directories and ALL their contents"
  printf "  (including rollback scripts and ACL backups).\n\n"

  typeset _I=0
  typeset _V0=""  _V1=""  _V2=""  _V3=""  _V4=""  _V5=""  _V6=""  _V7=""  _V8=""  _V9=""
  typeset _V10="" _V11="" _V12="" _V13="" _V14="" _V15="" _V16="" _V17="" _V18="" _V19=""
  typeset _V20="" _V21="" _V22="" _V23="" _V24="" _V25="" _V26="" _V27="" _V28="" _V29=""

  for _D in "${BASE_OUT}"/discovery_*; do
    [[ -d "$_D" ]] || continue
    eval "_V${_I}=\${_D}"
    _I=$(( _I + 1 ))
    [[ $_I -ge 30 ]] && break
  done

  if [[ $_I -eq 0 ]]; then
    printf "  No run directories found.\n%s\n" "$SEP"
    return
  fi

  printf "  Total runs found: %d\n" "$_I"
  ask _KEEP "Keep newest N runs (0 to cancel): "
  is_int "$_KEEP" || { warn "Integer required"; return; }
  [[ "$_KEEP" -eq 0 ]] && return
  if [[ "$_KEEP" -ge $_I ]]; then
    printf "  Nothing to purge — all %d runs will be kept.\n" "$_I"
    return
  fi

  typeset _DEL=$(( _I - _KEEP ))
  printf "\n  Will permanently DELETE %d oldest run(s):\n" "$_DEL"

  typeset _J=0
  while [[ $_J -lt $_DEL ]]; do
    typeset _DD
    eval "_DD=\${_V${_J}}"
    typeset _SZ
    _SZ=$(du -sk "$_DD" 2>/dev/null | awk '{print $1}')
    printf "    %6d KB   %s\n" "${_SZ:-0}" "$_DD"
    _J=$(( _J + 1 ))
  done

  printf "\n"
  confirm_yes "Permanently delete these $_DEL run(s)?" || {
    printf "Aborted.\n"
    return
  }

  _J=0
  while [[ $_J -lt $_DEL ]]; do
    typeset _DD
    eval "_DD=\${_V${_J}}"
    if rm -rf "$_DD" 2>/dev/null; then
      GREEN "  Deleted: $_DD"
    else
      RED "  Failed:  $_DD"
    fi
    _J=$(( _J + 1 ))
  done
  printf "%s\n" "$SEP"
}

# 33 — Diagnostics menu
menu_diagnostics() {
  while :; do
    printf "\n%s\n" "$SEP"
    BOLD " DIAGNOSTICS & TROUBLESHOOTING"
    printf "%s\n" "$SEP"
    printf "  1) Environment check      — verify perl, aclget, disk space\n"
    printf "  2) Tail a log file        — view end of any log\n"
    printf "  3) Search logs            — grep for FAIL/WARN/ERROR/path\n"
    printf "  4) Show checkpoints       — list interrupted/resumable scans\n"
    printf "  5) Clear a checkpoint     — discard resume state\n"
    printf "  6) Validate CSV           — check CSV column integrity\n"
    printf "  7) Rollback integrity     — syntax + touched CSV check\n"
    printf "  8) Disk usage report      — space used by all run dirs\n"
    printf "  9) Purge old runs         — delete oldest run dirs\n"
    printf "  0) Back\n"
    printf "%s\n" "$SEP"
    ask _CH "Choice: "
    case "$_CH" in
      1) diag_env ;;
      2) diag_tail_log ;;
      3) diag_grep_log ;;
      4) diag_checkpoints ;;
      5) diag_clear_ckpt ;;
      6) diag_validate_csv ;;
      7) diag_rollback_integrity ;;
      8) diag_disk_usage ;;
      9) diag_purge_runs ;;
      0) return ;;
      *) warn "Invalid choice" ;;
    esac
    pause
  done
}

###############################################################################
# SECTION 34 — MAIN MENU
###############################################################################
main_menu() {
  load_conf
  while :; do
    printf "\n%s\n" "$SEP"
    BOLD " Permission Hardening Suite — AIX  v${VERSION}"
    printf " Host: %s   Base: %s\n" "$HOST" "$BASE_OUT"
    printf "%s\n" "$SEP"
    printf "  1) Discovery      — scan for insecure permissions\n"
    printf "  2) Remediation    — dry-run then apply fixes\n"
    printf "  3) Rollback       — restore previous permissions\n"
    printf "  4) Verify         — confirm remediation success\n"
    printf "  5) Reports        — view summaries / CSVs\n"
    printf "  6) Settings       — configure defaults & performance\n"
    printf "  7) Diagnostics    — troubleshooting, logs, integrity\n"
    printf "  0) Exit\n"
    printf "%s\n" "$SEP"
    ask _CH "Select: "
    case "$_CH" in
      1) menu_discovery ;;
      2) menu_remediation ;;
      3) menu_rollback ;;
      4) menu_verify ;;
      5) menu_reports ;;
      6) menu_settings ;;
      7) menu_diagnostics ;;
      0) printf "Exiting.\n"; exit 0 ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

###############################################################################
# SECTION 35b — LONG-RUN / BACKGROUND EXECUTION HELPERS
#
# For 600GB mount points that take multiple hours:
#
# OPTION 1 — nohup + background (simplest)
#   nohup ksh perm_hardening_aix.ksh --discover -r "/download" \
#     >/lparrecovery/discover_bg.log 2>&1 &
#   echo "PID: $!"
#   tail -f /lparrecovery/discover_bg.log        # monitor in another session
#
# OPTION 2 — screen/tmux (survives SSH disconnect)
#   screen -S perm_harden
#   ksh perm_hardening_aix.ksh --discover -r "/download"
#   Ctrl-A D  (detach)
#   screen -r perm_harden  (reattach from new session)
#
# OPTION 3 — batch mode with progress monitoring
#   ksh perm_hardening_aix.ksh --discover -r "/download" \
#     >/lparrecovery/discover.log 2>&1 &
#   # Monitor via: ksh perm_hardening_aix.ksh --status
#
# OPTION 4 — cron (fully unattended)
#   0 22 * * 5 root ksh /opt/tools/perm_hardening_aix.ksh \
#     --discover -r "/download /cdirect" \
#     >> /lparrecovery/perm_discover_$(date +\%Y\%m\%d).log 2>&1
#
# RESUME after interruption:
#   Simply re-run the SAME command — the .scan_checkpoint file in the
#   run directory will cause processing to resume from where it stopped.
#   The candidate list (phase 1 find) does NOT need to re-run — only the
#   stat/permission-check phase (phase 2) resumes from checkpoint.
#   NOTE: If the run directory does not exist yet (phase 1 was interrupted),
#   the scan restarts cleanly from the beginning.
###############################################################################

###############################################################################
# SECTION 35c — --status VERB
# Shows live status of any currently running scan or the last completed scan.
# Usage: ksh perm_hardening_aix.ksh --status
###############################################################################
show_status() {
  load_conf
  printf "\n%s\n" "$SEP"
  BOLD " Scan Status — $HOST"
  printf "%s\n" "$SEP"

  # ── Find the most recent run directory ────────────────────────────────────
  typeset _LATEST=""
  for _D in "${BASE_OUT}"/discovery_*; do
    [[ -d "$_D" ]] && _LATEST="$_D"
  done

  if [[ -z "$_LATEST" ]]; then
    printf "  No run directories found under %s\n" "$BASE_OUT"
    printf "%s\n" "$SEP"
    return
  fi

  printf "  Latest run: %s\n\n" "$_LATEST"

  # ── Check for active checkpoint (scan in progress or interrupted) ─────────
  typeset _CKPT="${_LATEST}/.scan_checkpoint"
  if [[ -r "$_CKPT" ]]; then
    typeset _CKPT_LN
    _CKPT_LN=$(cat "$_CKPT" 2>/dev/null)
    YELLOW "  STATUS: INTERRUPTED / RESUMABLE"
    printf "  Checkpoint at candidate line: %s\n" "$_CKPT_LN"
    printf "  To resume: re-run the same --discover command\n\n"
  fi

  # ── Check if a scan process is currently running ──────────────────────────
  typeset _PIDS
  _PIDS=$(ps -ef 2>/dev/null | grep "perm_hardening_aix" | \
          grep -v grep | awk '{print $2}')
  if [[ -n "$_PIDS" ]]; then
    GREEN "  STATUS: RUNNING"
    printf "  PIDs: %s\n\n" "$_PIDS"
  fi

  # ── Show run.meta if present ───────────────────────────────────────────────
  typeset _META="${_LATEST}/run.meta"
  if [[ -r "$_META" ]]; then
    printf "  Run metadata:\n"
    while IFS='=' read _K _V; do
      case "$_K" in
        '#'*|'') continue ;;
        *) printf "    %-18s %s\n" "${_K}:" "$_V" ;;
      esac
    done <"$_META"
    printf "\n"
  fi

  # ── Show latest log tail ───────────────────────────────────────────────────
  typeset _LOG
  _LOG=$(ls -1t "${_LATEST}"/*.log 2>/dev/null | head -1)
  if [[ -n "$_LOG" ]]; then
    printf "  Latest log: %s\n" "$_LOG"
    printf "  Last 20 lines:\n%s\n" "$SEP2"
    tail -20 "$_LOG"
    printf "%s\n" "$SEP2"

    # Extract timing info from log
    typeset _TIMING
    _TIMING=$(grep "^.*TIMING:" "$_LOG" 2>/dev/null | tail -10)
    if [[ -n "$_TIMING" ]]; then
      printf "\n  Timing summary (last 10 entries):\n"
      printf "%s\n" "$_TIMING"
    fi
  fi

  # ── Show any active remediation runs ─────────────────────────────────────
  typeset _REMDIR
  _REMDIR=$(ls -1dt "${_LATEST}"/remediation_* 2>/dev/null | head -1)
  if [[ -n "$_REMDIR" ]]; then
    printf "\n  Latest remediation: %s\n" "$_REMDIR"
    typeset _RLOG
    _RLOG=$(ls -1t "${_REMDIR}"/*.log 2>/dev/null | head -1)
    if [[ -n "$_RLOG" ]]; then
      printf "  Remediation log tail:\n%s\n" "$SEP2"
      tail -10 "$_RLOG"
      printf "%s\n" "$SEP2"
    fi
    # Show touched CSV progress
    typeset _TC
    _TC=$(ls -1t "${_REMDIR}"/remediate_touched_*.csv 2>/dev/null | head -1)
    if [[ -n "$_TC" ]]; then
      typeset _DONE _FAIL _SKIP
      _DONE=$(awk -F',' 'NR>1&&$10=="\"OK\""    {c++}END{print c+0}' "$_TC")
      _FAIL=$(awk -F',' 'NR>1&&$10~/FAIL/       {c++}END{print c+0}' "$_TC")
      _SKIP=$(awk -F',' 'NR>1&&$10=="\"DRYRUN\"" {c++}END{print c+0}' "$_TC")
      printf "\n  Touched CSV progress:\n"
      printf "    Applied (OK):   %d\n" "$_DONE"
      printf "    Failed:         %d\n" "$_FAIL"
      printf "    Dry-run rows:   %d\n" "$_SKIP"
    fi
  fi

  printf "\n%s\n" "$SEP"

  # ── Practical guidance ────────────────────────────────────────────────────
  printf "\n  HOW TO RUN FOR 600GB MOUNT POINTS:\n\n"
  printf "  1) Background with nohup (SSH can disconnect safely):\n"
  printf "     nohup ksh %s --discover -r \"/download\" \\\n" "$0"
  printf "       >%s/discover_bg.log 2>&1 &\n" "$BASE_OUT"
  printf "     echo PID: \$!\n\n"

  printf "  2) Monitor progress from another session:\n"
  printf "     tail -f %s/discover_bg.log\n\n" "$BASE_OUT"

  printf "  3) Check status at any time:\n"
  printf "     ksh %s --status\n\n" "$0"

  printf "  4) If session drops — just re-run same command:\n"
  printf "     Resume is automatic via checkpoint file.\n\n"

  printf "  5) For remediation in background:\n"
  printf "     nohup ksh %s --remediate \\\n" "$0"
  printf "       -c <discovery.csv> -H <hints.csv> -l HIGH \\\n"
  printf "       >%s/remediate_bg.log 2>&1 &\n\n" "$BASE_OUT"

  printf "  6) Recommended settings for 600GB scans (set in Settings menu):\n"
  printf "     SKIP_REC=1  SKIP_DU=1  CHUNK_SIZE=5000\n"
  printf "     RESUME_ENABLED=1  LOG_TIMING=1  FIND_TIMEOUT=14400\n\n"

  printf "%s\n" "$SEP"
}
batch_usage() {
cat <<'BATCHHELP'
perm_hardening_aix.ksh v2.1.0 — Batch Usage

INTERACTIVE (default — no arguments):
  ksh perm_hardening_aix.ksh

BATCH / CRON:

  DISCOVER:
    ksh perm_hardening_aix.ksh --discover \
        -r "<roots>"            Required: space-separated, quoted
        [-M WW|777|777D]        Permission mode (default: WW)
        [-C AUTO|STAT|FIND]     Candidate mode (default: AUTO)
        [-I]                    Include /tmp itself in findings
        [-o <outbase>]          Override output base directory

  REMEDIATE:
    ksh perm_hardening_aix.ksh --remediate \
        -c <discovery.csv>      Required
        [-H <hints.csv>]        Use suggested modes + risk filter
        [-m <mode>]             Override mode (e.g. 0750 or 2770)
        [-o <owner>]            Override owner (- to keep)
        [-g <group>]            Override group (- to keep)
        [-l LOW|MEDIUM|HIGH|ALL] Risk level filter (requires -H)
        [-d <dir_prefix>]       Scope to directory prefix
        [-p <exact_path>]       Scope to one specific path
        [-O <outdir>]           Override output directory
        [-n]                    Dry-run only — no changes applied

  ROLLBACK:
    ksh perm_hardening_aix.ksh --rollback \
        -R <rollback.sh>        Full rollback
        [-n]                    Dry-run
    or
        -T <touched.csv>        Prefix-filtered rollback
        -P <path_prefix>
        [-n]                    Dry-run

  VERIFY:
    ksh perm_hardening_aix.ksh --verify \
        -T <touched.csv>        Required
        [-O <outdir>]           Output directory for report

  HELP:
    ksh perm_hardening_aix.ksh --help

NOTES:
  - In batch --remediate without -n, a mandatory dry-run pass runs first,
    then apply proceeds automatically.
  - Settings from ~/.perm_hardening_aix.conf are loaded automatically.
BATCHHELP
}

# ── Parse the verb ─────────────────────────────────────────────────────────
_BMODE="interactive"
case "${1:-}" in
  --discover)  _BMODE="discover";  shift ;;
  --remediate) _BMODE="remediate"; shift ;;
  --rollback)  _BMODE="rollback";  shift ;;
  --verify)    _BMODE="verify";    shift ;;
  --help|-h)   batch_usage; exit 0 ;;
esac

# ── Parse batch options ────────────────────────────────────────────────────
_BR="" _BSM="" _BCAND="" _BINCL=0 _BOUT=""
_BCSV="" _BHINTS="" _BOVM="" _BOVOWN="" _BOVGRP=""
_BFLVL="" _BTDIR="" _BTPATH="" _BODDIR="" _BDRY=0
_BRBSH="" _BRBPFX="" _BTCSV=""

if [[ "$_BMODE" != "interactive" ]]; then
  while getopts ":r:M:C:Io:c:H:m:g:l:d:p:O:nR:P:T:" _OPT; do
    case "$_OPT" in
      r) _BR="$OPTARG" ;;
      M) _BSM="$OPTARG" ;;
      C) _BCAND="$OPTARG" ;;
      I) _BINCL=1 ;;
      o) if [[ "$_BMODE" = "discover" ]]; then
           _BOUT="$OPTARG"
         else
           _BOVOWN="$OPTARG"
         fi ;;
      c) _BCSV="$OPTARG" ;;
      H) _BHINTS="$OPTARG" ;;
      m) _BOVM="$OPTARG" ;;
      g) _BOVGRP="$OPTARG" ;;
      l) _BFLVL=$(printf "%s" "$OPTARG" | tr '[:lower:]' '[:upper:]') ;;
      d) _BTDIR="$OPTARG" ;;
      p) _BTPATH="$OPTARG" ;;
      O) _BODDIR="$OPTARG" ;;
      n) _BDRY=1 ;;
      R) _BRBSH="$OPTARG" ;;
      P) _BRBPFX="$OPTARG" ;;
      T) _BTCSV="$OPTARG" ;;
      :) die "Option -$OPTARG requires an argument" ;;
      ?) die "Unknown option: -$OPTARG" ;;
    esac
  done
fi

###############################################################################
# FUNCTION INVENTORY (for verification — every function defined in this file)
#
# SECTION 2  : BOLD RED GREEN YELLOW CYAN
# SECTION 3  : tlog flog tlog_timing die warn pause confirm confirm_yes is_int
# SECTION 4  : ask
# SECTION 5  : load_conf save_conf
# SECTION 6  : prog_init prog_clear prog_done prog_phase prog_high
#              _mkbar prog_bar prog_rem
# SECTION 7  : (PERL_OK set)
# SECTION 8  : epoch_now elapsed_str
# SECTION 9  : fast_stat parse_fs
# SECTION 10 : get_octal get_og get_mtime get_size_kb get_adays
#              get_type count_rec acl_marker save_acl csv_q csv_uq
# SECTION 11 : perm_matches
# SECTION 12 : detect_cand_mode
# SECTION 13 : classify_risk
# SECTION 14 : suggest_rem
# SECTION 15 : ckpt_init ckpt_save ckpt_clear
# SECTION 16 : csv_set_result
# SECTION 17 : (counters _DT _DH _DM _DL _DA _DE)
# SECTION 18 : process_one
# SECTION 19 : scan_root
# SECTION 20 : run_discovery
# SECTION 21 : get_hint_field plan_target in_scope
# SECTION 22 : build_rollback
# SECTION 23 : run_remediation
# SECTION 24 : run_rollback_script run_prefix_rollback
# SECTION 25 : run_verify
# SECTION 26 : select_run select_file select_dir_glob
# SECTION 27 : menu_discovery
# SECTION 28 : menu_remediation
# SECTION 29 : menu_rollback
# SECTION 30 : menu_verify
# SECTION 31 : menu_reports
# SECTION 32 : menu_settings
# SECTION 33 : diag_env diag_tail_log diag_grep_log diag_checkpoints
#              diag_clear_ckpt diag_validate_csv diag_rollback_integrity
#              diag_disk_usage diag_purge_runs menu_diagnostics
# SECTION 34 : main_menu
# SECTION 35 : batch_usage
# SECTION 36 : (entry point — interactive or batch dispatch)
###############################################################################
if [[ $(id -u) -ne 0 ]]; then
  YELLOW "WARNING: Not running as root — remediation and rollback will fail."
fi

if [[ "$_BMODE" = "interactive" ]]; then
  main_menu
else
  load_conf

  case "$_BMODE" in
    discover)
      [[ -z "$_BR"    ]] && _BR="$DEFAULT_ROOTS"
      [[ -z "$_BSM"   ]] && _BSM="$DEFAULT_MODE"
      [[ -z "$_BCAND" ]] && _BCAND="$DEFAULT_CAND"
      [[ -n "$_BOUT"  ]] && BASE_OUT="$_BOUT"
      case "$_BSM" in
        WW|777|777D) : ;;
        *) die "Invalid -M mode: $_BSM (use WW|777|777D)" ;;
      esac
      case "$_BCAND" in
        AUTO|STAT|FIND) : ;;
        *) die "Invalid -C mode: $_BCAND (use AUTO|STAT|FIND)" ;;
      esac
      typeset _BET=$(( 1 - _BINCL ))
      run_discovery "$_BR" "$_BSM" "$_BCAND" "$_BET"
      ;;

    remediate)
      [[ -z "$_BCSV" ]] && die "--remediate requires -c <discovery.csv>"
      [[ ! -r "$_BCSV" ]] && die "Cannot read CSV: $_BCSV"
      typeset _BOD
      if [[ -n "$_BODDIR" ]]; then
        _BOD="$_BODDIR"
      else
        _BOD="$(dirname "$_BCSV")/remediation_$(date +%Y%m%d_%H%M%S)"
      fi
      if [[ $_BDRY -eq 0 ]]; then
        printf "Batch remediate: running mandatory dry-run first...\n"
        run_remediation "$_BCSV" "$_BHINTS" "${_BOD}_dryrun" \
          "$_BTPATH" "$_BTDIR" "$_BFLVL" \
          "$_BOVM" "$_BOVOWN" "$_BOVGRP" 1
        printf "Dry-run complete. Proceeding to apply...\n"
        run_remediation "$_BCSV" "$_BHINTS" "$_BOD" \
          "$_BTPATH" "$_BTDIR" "$_BFLVL" \
          "$_BOVM" "$_BOVOWN" "$_BOVGRP" 0
      else
        run_remediation "$_BCSV" "$_BHINTS" "$_BOD" \
          "$_BTPATH" "$_BTDIR" "$_BFLVL" \
          "$_BOVM" "$_BOVOWN" "$_BOVGRP" 1
      fi
      ;;

    rollback)
      if [[ -n "$_BRBPFX" ]]; then
        [[ -z "$_BTCSV" ]] && \
          die "Prefix rollback (-P) requires -T <touched.csv>"
        run_prefix_rollback "$_BTCSV" "$_BRBPFX" "$_BDRY"
      else
        [[ -z "$_BRBSH" ]] && die "--rollback requires -R <rollback_script>"
        run_rollback_script "$_BRBSH" "$_BDRY"
      fi
      ;;

    verify)
      [[ -z "$_BTCSV" ]] && die "--verify requires -T <touched.csv>"
      typeset _BVOD
      if [[ -n "$_BODDIR" ]]; then
        _BVOD="$_BODDIR"
      else
        _BVOD=$(dirname "$_BTCSV")
      fi
      run_verify "$_BTCSV" "$_BVOD"
      ;;
  esac
fi