#!/bin/sh

#
# Configcheck: check and track environment configuration / state
#
# Copyright (c) 2014, Adrian Penisoara <ady (at) bsdconsultants.com>
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 
# * Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
# 
# * Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# 

# Avoid some classic warnings in Shellcheck
# Reason: we want to remain compatible with legacy shells and avoid any bash'isms
# Disabling globally the following checks:
#  * SC2006: Use $(..) instead of legacy `..`.
#  * SC2092: Remove backticks to avoid executing output.
#  * SC2162: read without -r will mangle backslashes.
#  * SC2086: Double quote to prevent globbing and word splitting. [temporary]
# shellcheck disable=SC2006,SC2092,SC2162,SC2086

SCRIPTNAME=`basename $0`
SCRIPTDIR=`dirname $0`
CONFIGDIR=`cd $SCRIPTDIR ; pwd`
CONFIGFILE="$CONFIGDIR/configcheck.conf"

# Give a chance to override the default configuration file
#  -- in the first pair of command arguments
if [ $# -ge 2 -a "$1" = "-f" ]; then
    CONFIGFILE="$2"
    CONFIGDIR=`dirname $CONFIGFILE`
    CONFIGDIR=`cd $CONFIGDIR ; pwd`
    shift 2
fi

# Source own configuration file
if [ -r "$CONFIGFILE" ] ; then
    # shellcheck source=configcheck.conf
    . "$CONFIGFILE"
else
    echo "ERROR: configuration file ($CONFIGFILE) is not readable"
    exit 1
fi

# Helper function to display help for command syntax
usage() {
    echo "Usage: $SCRIPTNAME [-f <cfg. file>] [-c] [-d] [-n] [-m <state>] [-r recipients] [-s subject] [list1 list2 ...]"
    echo "    -c    (re)create the store"
    echo "    -d    enable debugging (similar to setting DEBUG=yes in environment)"
    echo "    -f    specify a master configuration file (must be first argument)"
    echo "            Note: this also changes the default configuration directory in the same location"
    echo "    -h    display help (this page)"
    echo "    -r    override default recipients list of the report email"
    echo "    -s    override default subject of the report email"
    echo "    -n    dry run (nothing will be saved/reported)"
    echo "    -m    enable/disable saving file checksums in the store"
    echo "            Possible values for <state>: y/n/on/off/true/false"
    echo "    -v    verbose output"
    echo
    echo "The rest of the command line will be interpreted as config list filenames to be processed"
    exit 100
}

# Parse command line arguments
DRYRUN=false
VERBOSE=false
while getopts cdf:hnm:r:s:v arg
do
    case $arg in
        c)  CREATESTORE=true ;;
        d)  DEBUG=true ;;
        f)  echo "Error: -f argument must be first on the command line !" ; exit 10 ;;
        h)  usage ;;
        n)  DRYRUN=true ;;
        m)  case "$OPTARG" in
                on|ON|true|TRUE|y|Y) STORECHECKSUM=true ;;
            off|OFF|false|FALSE|n|N) STORECHECKSUM=false ;;
                                  *) echo "invalid value for checksum state"
                                     usage ;;
            esac ;;
        r)  MAILRECIPIENTS="$OPTARG";;
        s)  MAILSUBJECT="$OPTARG";;
        v)  VERBOSE=true ;;

        ?)  echo "Unknown option -$arg"
            usage ;;
    esac        
done
shift `expr $OPTIND - 1`

case ${DEBUG:-false} in
    [oO][nN] | [yY] | [yY][eE][sS] | [tT][rR][uU][eE])
        echo Debugging is turned on
        echo Dry run: $DRYRUN
        echo Verbose: $VERBOSE
        echo Store checksums: $STORECHECKSUM
        echo Config file: $CONFIGFILE
        echo Locale setup in environment:
        env | $GREPCMD "^LANG\>"
        env | $GREPCMD "^LC_" | sort
        # Check for prefixes defined as variables
        echo "Prefixes detected in environment:"
        for PREFIX in $PREFIXDIRLIST ; do
            VAR="\$$PREFIX"                   # e.g. "$BASEDIR"
            VAR=`eval echo "$VAR" | sed -e 's/^\\$//'`   # e.g. "DSEE_BASEDIR"
            env | $GREPCMD "^$VAR\>"
        done | sort | uniq
        DEBUG=''
        ;;
    *)
        DEBUG=':'
        ;;
esac

#
# Helper functions
#

# Get disk usage of target file/directory
diskusage() {
    if [ -e "$1" ]; then
        result=`$DISKUSAGECMD "$1" | tail -1 | awk '{ print $1 }'`
    else
        result=""
    fi
}

# Get disk free in target directory
diskfree() {
    if [ -e "$1" ]; then
        result=`$DISKFREECMD "$1" | tail -1 | awk '{ print $(NF-2) }'`
    else
        result=""
    fi
}

# Save a file (copy) in a store
savefile() {
    source="$1"   # source file
    target="$2"   # destination file

    [ -z "$source" -o -z "$target" ] && return 1

    diskusage "$source"
    if [ -n "$result" ] && [ "$result" -gt $STORE_MAXFILESIZE ]; then
        echo "ERROR: will not save (copy) file $source -- size is over limit"
        echo "ERROR: will not save (copy) file $source -- size is over limit" >> $report
        [ $VERBOSE = true -o -z "$DEBUG" ] && \
            echo "(file size $result Kb, limit $STORE_MAXFILESIZE Kb)"
        return 2
    fi

    targetdir=`dirname "$target"`
	diskfree "$targetdir"
    if [ -n "$result" ] && [ "$result" -lt $STORE_MINDISKFREE ]; then
        echo "ERROR: will not save (copy) file $source -- not enough free disk space in target store"
        echo "ERROR: will not save (copy) file $source -- not enough free disk space in target store" >> $report
        [ $VERBOSE = true -o -z "$DEBUG" ] && \
            echo "($result Kb available in $targetdir, minimum required $STORE_MINDISKFREE Kb)"
        return 3
    fi

    # WARNING:
    # mkdir operation may fail if symlinks are present at the end of the path
    # that's why you should prevent using symlinks underneath store directories
    $DEBUG echo "copy: $source -> $target"
    mkdir -p "$targetdir"
    # we need write permissions in order to alter the file contents
    [ -e "$target" -a ! -w "$target" ] && chmod u+w "$target"
    # now attempt copying the file -- protect against weird file names
    $COPYCMD -- "$source" "$target"
    ret=$?
    [ $ret -ne 0 ] && echo "ERROR: failed to copy ["`pwd`"][$source] over to [$target]"
    return $ret
}

# Checksumming a file
checksumfile() {
    cat "$1" | $CKSUMCMD > "$2"
}

# Print error and exit
errx() {
    echo "ERROR: $2"
    exit $1
}

# Timestamp the run, check environment
echo
echo "[ $SCRIPTNAME started on "`date`" ]"

# In case we are requested to create the store directory, ask the user if he
# would like for the existing store directory to be removed before we recreate it
if [ -n "$CREATESTORE" -a -r "$STOREDIR" ]; then
    echo
    echo "It would be a good idea to remove the current store directory..."
    echo "(WARNING: you will loose your current state/history in $STOREDIR !)"
    echo "Remove the old store directory ? [y/n] "
    read x
    if [ "$x" = "y" ]; then
        echo "Removing any leftover $STOREDIR"
        rm -rf "$STOREDIR"
    fi
fi
# Create store directories if (some are) missing
if [ -n "$CREATESTORE" -o  ! \( -d "$STOREDIR" -a -d "$WORKSTORE" -a \( -z "$HISTORYSTORE" -o -d "$HISTORYSTORE" \) \) ]; then
    echo "Info: (re)creating store directory structure into $STOREDIR"
    mkdir -p "$WORKSTORE" "$HISTORYSTORE" || errx 1 "Cannot create store directories in $STOREDIR"
    for d in "$WORKSTORE" "$HISTORYSTORE" ; do
        [ -z "$d" ] && continue
        for PREFIX in $PREFIXDIRLIST ; do
            VAR="\$$PREFIX"               # e.g. "$BASEDIR"
            sd=`eval echo ${VAR}_SUBDIR`  # e.g. "_base"
            $DEBUG echo "Creating store subdirectory $d/$sd"
            mkdir -p "$d/$sd" || errx 2 "Cannot create store subdirectory $d/$sd"
        done
    done
fi
# Terminate if request was to (re)create the store
[ -n "$CREATESTORE" ] && exit 0

# Prepare temporary work directory --
# first check if enough free disk space is available on the target filesystem
diskfree ${TMPDIR:=/tmp}
if [ $result -lt $TMPMINFREE ]; then
    echo "ERROR: Temporary filesystem $TMPDIR is less than $TMPMINFREE Kb free (now: $result)"
    exit 2
fi
# then prepare a work directory
WORKTMPDIR="${TMPDIR}/${SCRIPTNAME}.$$"
mkdir -p "$WORKTMPDIR"
if [ $? -eq 0 ]; then
    $DEBUG echo "Created temp work directory: $WORKTMPDIR"
    $DEBUG false && trap '/bin/rm -rf $WORKTMPDIR; exit 255' 1 2 6 13 15
else
    errx 2 "failed to create temporary work directory (tried: $WORKTMPDIR)"
fi

# Report preparations
report=$WORKTMPDIR/report.txt
needtoreport=$WORKTMPDIR/doreport
rm -rf "$needtoreport"
# shellcheck disable=SC2129
echo "Report for configuration files check on ${HOSTNAME_SHORT}" > $report
echo "==================================================" >> $report
echo >> $report
echo "Conf: [$CONFIGDIR/]"`basename $CONFIGFILE` >>$report
echo "Date:" `date '+%a %d %B %Y'` >> $report
echo "Time:" `date '+%T %Z'` >> $report
echo "Host: $HOSTNAME_FULL" >> $report
echo "User: $LOGNAME" >> $report
echo "Base: $DEFAULTDIR" >> $report
echo >> $report
echo >> $report


# Build the list of config lists to process
cd "$CONFIGLISTDIR"
if [ $# -ge 1 ]; then
    # a list is specified on the command line
    configlists="$@"
else
    # build a list from the current configuration directory
    configlists=*${CONFIGLISTSUFFIX}
fi
$DEBUG echo "Expanded config files list to: $configlists"

for list in $configlists ; do
    # Detect absolute/relative paths for the listfiles
    if `echo "$list" | $GREPQCMD '^/'`; then
        listfile="$list"
    else
        listfile="$CONFIGLISTDIR/$list"
    fi
    if [ ! -r "$listfile" ]; then
        echo "WARNING: cannot read configuration list $listfile -- skipping"
        continue
    fi
    echo "==> Processing list file $list"

    # Initialize directory environment for a new config list
    basename=""
    basedir=""
    store_subdir=""
    workdir=""
    workdir_set=NO
    
    # Read statements in the list file by line
    while read listline ; do		# input is redirected at end of while loop
        $DEBUG echo "Read entry: $listline"
        statement=`echo "$listline" | sed -e 's/#.*$//'`
        comment=`echo "$listline" | $GREPCMD '#' | sed -e 's/^[^#]*# *\(.*\) *$/\1/'`
        $DEBUG echo "Statement: [$statement]"
        $DEBUG echo "Comment: [$comment]"

        dir=""      # marker for whether we need to change directory
        # Check for change directory statements (starts with "@")
        if `echo "$statement" | $GREPQCMD '^@'`; then
            dir=`echo "$statement" | cut -f2 -d '@'`
            
        elif [ $workdir_set = NO ]; then
            # Re-initialize the working directory at beginning of a new config list
            dir="$DEFAULTDIR"
        fi

        # Is a directory change required ?
        if [ -n "$dir" ]; then
            # Evaluate the expression to expand any env variables
            dir=`eval echo "$dir"`
            $DEBUG echo "Detected 'cd' statement (or changing to default directory) towards: [$dir]"
            # Recognize well known paths from configuration file:
            #           $BASEDIR, $HOMEDIR, $ROOTDIR, $DEFAULTDIR
            # last in the list must be $DEFAULTDIR to leave as default
            for PREFIX in $PREFIXDIRLIST ; do
                # heavy variable expansion going on here -- beware !
                VAR="\$$PREFIX"                 # e.g. "$HOMEDIR"
                basename=`eval echo $VAR`       # e.g. "$HOME"
                basedir=`eval echo $basename`   # e.g. "/home/user"
                store_subdir=`eval echo ${VAR}_SUBDIR`  # e.g. "_home"
                if `echo $dir | $GREPQCMD "^/*$basedir/*"`; then
                    dir=`echo $dir | sed -e "s&^/*$basedir/*&&"`
                    $DEBUG echo "Detected prefix $basename -- dir shortened to [$dir]"
                    break
                fi
            done    

            $DEBUG echo "Trying to change directory to [$dir] within $basedir"
            [ -d "$basedir/$dir" ] && cd "$basedir/$dir"
            if [ $? -eq 0 ] ; then
                $DEBUG echo Current directory: `pwd`
                workdir="$dir"
                [ $workdir_set = NO ] || continue  # only if dir change was caused by an "@" statement
                workdir_set=YES
            else
                echo "ERROR: failed to change directory to [$dir] in $basedir -- aborting current file list $listfile"
                [ $workdir_set = NO ] && echo "(we tried to cwd to default directory $DEFAULTDIR)"
                break
            fi
        fi

        # Check for diff output filtering (statement begins with +/-)
        if `echo "$statement" | $GREPQCMD '^[+-]'`; then
            # Marker is present, we need to prepare a grep command to filter diff output
            diff_filter=`echo "$statement" | cut -c 1`
            $DEBUG echo "Detected filtering marker: [$diff_filter]"
            # We allow using another set of diff arguments when filtering is in effect
            #  -- we particularly preffer context diff format which separates changes from additions/deletions
            diff_cmd="$DIFFCMD $DIFFARGS_FILTERING"
            # Adapt grep filter based on the diff output format specified above
            if `echo " $DIFFARGS_FILTERING" | $GREPQCMD -E -- '( -[a-zA-Z]*[uU]| --unified\>)'`; then
                : # modifier is already compatible to unified diff output format
            elif `echo " $DIFFARGS_FILTERING" | $GREPQCMD -E -- '( -[a-zA-Z]*[cC]| --context\>)'`; then
                diff_filter="$diff_filter "
            else
                # default diff format
                diff_filter=`echo "$diff_filter " | tr '+-' '><'`
            fi
            # Adjustment needed to use as grep argument
            diff_filter="^$diff_filter"
            # Drop off marker from statement, including any adjancent spacing
            statement=`echo "$statement" | sed -e 's/^[+-] *//'`
        else
            # nothing wil be filtered
            diff_filter=""
            diff_cmd="$DIFFCMD $DIFFARGS"
        fi

        # Check for pipe statement (ends with "|", like in Perl)
        pipefile=""
        pipeout=""
        if `echo "$statement" | $GREPQCMD '|[ 	]*$'` ; then        # inline TAB char !
            # (cleanup any extraneous spaces/tabs)
            pipeexpr=`echo "$statement" | sed -e 's/|[^|]*$//'`
            eval pipefile=\"$comment\"          # There may be variable expansion needed
            [ -z "$pipefile" ] && pipefile=`echo "$pipeexpr" | $CKSUMCMD | cut -f1 -d' '`".piped"
            $DEBUG echo "Pipe expression detected for file [$pipefile]: [$pipeexpr]"
            
            # Try to create an unique output file based on the suggested pipe file name
            pipeout="$WORKTMPDIR/pfiles/$pipefile"
            mkdir -p `dirname "$pipeout"` 2>/dev/null && touch "$pipeout" || \
                pipeout="$WORKTMPDIR/pipe.out" # but revert to a default if failed
            $DEBUG echo "Storing pipe output into [$pipeout]"
            # Execute pipe expression
            $DEBUG echo "Executing [$pipeexpr] (cwd: "`pwd`")"
            (eval "$pipeexpr" ) > "$pipeout"
            if [ $? -eq 0 ]; then
                $DEBUG echo Successful pipe expression execution
                # Avoid interpreting anymore the pipe expression
                statement=""
            else
                echo "WARNING: Pipe expression failed for [$pipefile]: ["`pwd`"][$pipeexpr]"
                continue
            fi
        fi

        # Process [resulting] file(s) for current statement
        for file in $pipefile $statement ; do
            # Make a distinction between target file name and target contents
            # This is needed to handle piped output (and possibly
            #      a real file does not exist)
            fpath=`echo "$basename/$workdir/$file" | sed -e 's#//*#/#g'`
            if [ -n "$pipefile" -a "$file" = "$pipefile" ]; then
                contents="$pipeout"
                fidentity="output for $fpath"
            else
                contents="$file"
                fidentity="file $fpath"
            fi

            if [ ! -r "$contents" ]; then
                echo "WARNING: File $basedir/$workdir/$contents is not readable -- skipping"
                continue
            fi

            $DEBUG echo "Processing $fidentity"
            # Default working file paths
            storefile=`echo "$WORKSTORE/$store_subdir/$workdir/$file" | sed -e 's#//*#/#g'`
            storefilecksum="${storefile}${CKSUMSUFFIX}"
            diffout="$WORKTMPDIR/diff.out"
            cksumout="$WORKTMPDIR/cksum.out"
            skipreport="false"

            # Analyze the file, assuming we stored an older version for it
            if [ -f "$storefile" ] ; then
                # File was already registered, compare it
                $diff_cmd -- "$storefile" "$contents" > $diffout 2>/dev/null
                ret=$?
                if [ $ret -eq 1 ]; then
                    echo "Change detected in $fidentity"
                    filtered=""

                    # Do we have to filter the diff output ?
                    if [ -n "$diff_filter" ]; then
                        $DEBUG echo "diff_cmd: [$diff_cmd]   diff_filter: [$diff_filter]"
                        $DEBUG echo "Unfiltered output:"
                        $DEBUG cat "$diffout"

                        # Filter diff results as established in code above
                        $GREPCMD "$diff_filter" "$diffout" > ${diffout}.filtered
                        ret=$?
                        if [ $ret -eq 1 ]; then
                            echo "Skipping: all changes in $fidentity are filtered by modifier"
                            skipreport=true
                        elif [ $ret -ne 0 ]; then
                            echo "WARNING: Diff filtering failed for $fidentity"
                            echo "Listing involved files:"
                            ls -l "$diffout" "${diffout}.filtered"
                            echo "WARNING: Diff filtering failed for $fidentity -- check output log" >> $report
                        else
                            diffout="${diffout}.filtered"
                            filtered="filtered "
                        fi
                    fi

                    # We have a usable diff output
                    [ $skipreport = false -a \( $VERBOSE = true -o -z "$DEBUG" \) ] && {
                        echo "Diff seen in ${diffout}"`[ -n "$diff_filter" ] && echo " (filtered)"`":"
                        cat "$diffout"
                    }

                    # Add diff to the report, unless it has to be skipped (due to complete filtering)
                    if [ $skipreport = false ] ; then
                        cat <<EOF >>$report

---------------------------------------------------------------------------------------------------
Detected ${filtered}change in $fidentity (showing first $DIFFNLINES lines):

EOF
                        # We cannot trim the diff header when diff output is already filtered
                        if [ -n "$diff_filter" ]; then
                            head -${DIFFNLINES} "$diffout" >> $report
                        else
                            head -${DIFFNLINES} "$diffout" | tail -n +${DIFFHEADERSKIP} >> $report
                        fi
                        echo >> $report
                    fi
                    echo
                elif [ $ret -eq 0 ]; then
                    [ $VERBOSE = true -o -z "$DEBUG" ] && echo "Skipping: $fidentity did not change"
                    continue
                elif [ $ret -ne 0 ]; then
                    echo "WARNING: Diff check failed for $fidentity !"
                    echo "Listing involved files (cwd:" `pwd` "):"
                    ls -l "$file"
                    ls -l "$contents"
                    ls -l "$storefile"
                    echo "WARNING: Diff check failed for $fidentity -- check output log" >> $report
                fi
            else
                # There is a new file/expression we need to register
                if [ -n "$pipefile" ]; then
                    msg="New pipe expression sensed for $fpath: [$pipeexpr]"
                else
                    msg="New file sensed: $fpath"
                fi
                echo "$msg"
                echo "$msg" >> $report
            fi

            # A change or error has been detected, so enable shipping the report
            #  -- unless this file is being skipped
            [ $skipreport = false ] && touch "$needtoreport"

            #
            # We now have a new/changed file to register
            #

            # ... unless we have a dry run
            [ $DRYRUN = "true" ] && continue

            # First store the file as reference for next round of checks
            $DEBUG echo "About to save store file [$storefile]"
            savefile "$contents" "$storefile"
            if [ $? -ne 0 ]; then
                echo "WARNING: Failed to store file [$storefile] !"
            fi

            # Attempt to store checksum file if enabled
            if [ "$STORECHECKSUM" = "true" ]; then
                checksumfile "$contents" "${storefilecksum}" || \
                    $DEBUG echo "Failed to store checksum for $fidentity"
            fi
            
            # Then retain history of the current version of the file
            # (if enabled)
            if [ -n "$HISTORYSTORE" ]; then
                tstamp=`$HISTDATECMD`
                histfile="$HISTORYSTORE/$store_subdir/$workdir/${file},${tstamp}"
                histfileparsed="${histfile},parsed"
                if [ -f "$file" ]; then
                    $DEBUG echo "About to save history file [$histfile]"
                    savefile "$file" "$histfile" || \
                        echo "WARNING: Failed to create history file [$histfile] for [$file] !"
                fi
                if [ -n "$pipefile" ]; then
                    $DEBUG echo "Storing also the parsed/pipe output for [$file]"
                    savefile "$contents" "$histfileparsed"
                fi
            fi

            # Cleanup after potentially big files
            $DEBUG false && rm -rf "$pipeout"
            $DEBUG false && rm -rf "$diffout"
        done
    done < $listfile
done

# Time to send the report, if we have one
if [ -f "$needtoreport" ]; then
    # send it out only if not a dry run and we have some recipients
    if [ $DRYRUN != true -a -n "$MAILRECIPIENTS" ]; then
        $DEBUG echo
        [ $VERBOSE = true -o -z "$DEBUG" ] && echo "Sending report to $MAILRECIPIENTS"
        $DEBUG echo
        $DEBUG cat $report
        cat $report | eval $MAILCMD -r \"$MAILFROM\"  -s \"$MAILSUBJECT\" $MAILRECIPIENTS
    # but print it anyway if in verbose mode
    elif [ $VERBOSE = true -o -z "$DEBUG" ]; then
        echo
        echo "Withheld report:"
        echo
        cat $report
    else
        echo "Info: report has not been sent."
    fi
fi

# Make sure we cleanup, unless debugging
$DEBUG false && rm -rf $WORKTMPDIR
# warn user about temporary leftovers in debugging mode
$DEBUG echo
$DEBUG echo "WARNING: Temporary directory $WORKTMPDIR has not been removed"

# vim: tabstop=4 shiftwidth=4 expandtab ai number
