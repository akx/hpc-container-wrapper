#!/bin/bash
umask 0002
SINGULARITY_BIND=""
set -e
set -u 

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source $SCRIPT_DIR/common_functions.sh
source $CW_BUILD_TMPDIR/_vars.sh


cd $CW_BUILD_TMPDIR
mkdir _deploy/bin
touch _deploy/common.sh
echo "#!/bin/bash" > _deploy/common.sh
if [[ "$CW_MODE" == "wrapcont" ]];then
    _CONTAINER_EXEC="singularity --silent exec  _deploy/$CW_CONTAINER_IMAGE"
    _RUN_CMD="singularity --silent exec \$DIR/../\$CONTAINER_IMAGE"
    _SHELL_CMD="singularity --silent shell \$DIR/../\$CONTAINER_IMAGE"
else
    _CONTAINER_EXEC="singularity --silent exec -B _deploy/$CW_SQFS_IMAGE:$CW_INSTALLATION_PATH:image-src=/ _deploy/$CW_CONTAINER_IMAGE"
    echo "SQFS_IMAGE=$CW_SQFS_IMAGE" >> _deploy/common.sh
    _RUN_CMD="singularity --silent exec -B \$DIR/../\$SQFS_IMAGE:\$INSTALLATION_PATH:image-src=/ \$DIR/../\$CONTAINER_IMAGE"
    _SHELL_CMD="singularity --silent shell -B \$DIR/../\$SQFS_IMAGE:\$INSTALLATION_PATH:image-src=/ \$DIR/../\$CONTAINER_IMAGE"
fi


_REAL_PATH_CMD='DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"'
_PRE_COMMAND="source \$DIR/../common.sh"
echo "CONTAINER_IMAGE=$CW_CONTAINER_IMAGE
INSTALLATION_PATH=$CW_INSTALLATION_PATH
SINGULARITYENV_PATH=\"$($_CONTAINER_EXEC bash -c 'echo $PATH')\"
SINGULARITYENV_LD_LIBRARY_PATH=\"$($_CONTAINER_EXEC bash -c 'echo $LD_LIBRARY_PATH')\"
export SINGULARITYENV_PATH=\"$(echo "${CW_WRAPPER_PATHS[@]}" | tr ' ' ':' ):\$SINGULARITYENV_PATH\"
">> _deploy/common.sh
if [[ ${CW_WRAPPER_LD_LIBRARY_PATHS+defined} ]]; then
    echo "export SINGULARITYENV_LD_LIBRARY_PATH=\"\$SINGULARITYENV_LD_LIBRARY_PATH:$(echo "${CW_WRAPPER_LD_LIBRARY_PATHS[@]}" | tr ' ' ':' )\"">> _deploy/common.sh
fi

if [[ "$CW_ISOLATE" == "yes" ]]; then
    # 
    echo "_DIRS=(${CW_MOUNT_POINTS[@]})" >> _deploy/common.sh
else
    echo "_DIRS=(\$(ls -1 / | awk '!/dev/' | sed 's/^/\//g' ))" >> _deploy/common.sh

if [[ "${CW_EXCLUDED_MOUNT_POINTS+defined}" ]];then
    echo "
        _excludes=( ${CW_EXCLUDED_MOUNT_POINTS[@]}  )
        for mp in \"\${_excludes}\";do
            _DIRS=( \"\${_DIRS[@]/\$mp}\")
        done
    ">> _deploy/common.sh

fi
    echo "export SINGULARITYENV_PATH=\"\$SINGULARITYENV_PATH:\$PATH\"
export SINGULARITYENV_LD_LIBRARY_PATH=\"\$SINGULARITYENV_LD_LIBRARY_PATH:\$LD_LIBRARY_PATH\"
" >> _deploy/common.sh
fi
echo "
for d in \"\${_DIRS[@]}\"; do
    if [[ -z \"\$SINGULARITY_BIND\" ]];then
`        `test -d \$d && export SINGULARITY_BIND=\"\$d\"
    else
        test -d \$d && export SINGULARITY_BIND=\"\$SINGULARITY_BIND,\$d\"
    fi
done
SINGULARITY_BIND=\"\$SINGULARITY_BIND,\$TMPDIR,\$TMPDIR:/tmp\"
export SINGULARITY_BIND" >> _deploy/common.sh




_SING_LIB_PATHS=()
_GENERATED_WRAPPERS=""

print_info "Creating wrappers" 1
for wrapper_path in "${CW_WRAPPER_PATHS[@]}";do
    print_info "Generating wrappers for $wrapper_path" 2
    if [[ "$CW_WRAP_ALL" == "yes" ]];then
        print_info "Wrapping all files" 3
        targets=($($_CONTAINER_EXEC ls -F $wrapper_path | grep -v "/"  | sed 's/.$//g' ))
    else
        print_info "Only wrapping executables" 3
        targets=($($_CONTAINER_EXEC ls -F $wrapper_path | grep "\*\|@" | sed 's/.$//g'))
    fi
    if [[ "$CW_ADD_LD" == "yes" ]]; then
        # Nasty hack
        # empty result -> no array defined

        lib_dirs=($($_CONTAINER_EXEC ls $wrapper_path/.. | grep "lib[64]*$" || true ))
        if [[ ${lib_dirs+defined} ]];then
            for d in "${lib_dirs[@]}"; do
                _SING_LIB_PATHS+=("$(dirname $wrapper_path)/$d")
            done
        fi
    fi
    if [[ ! ${targets+defined} ]];then
        print_err "Path $wrapper_path does not exist in container or is empty"
        false
    fi

    for target in "${targets[@]}"; do
        print_info "Creating wrapper for $target" 3
        echo -e "$_GENERATED_WRAPPERS" | grep "^$target$" &>/dev/null &&  print_warn "Multiple binaries with the same name" || true
    _GENERATED_WRAPPERS="$_GENERATED_WRAPPERS\n$target"
        echo "#!/bin/bash" > _deploy/bin/$target
        echo "$_REAL_PATH_CMD" >> _deploy/bin/$target
        echo "$_PRE_COMMAND" >> _deploy/bin/$target
        echo "
        if [[ -z \"\$SINGULARITY_NAME\" ]];then
            $_RUN_CMD  $wrapper_path/$target \"\$@\" 
        else
            $wrapper_path/$target \"\$@\"
        fi" >> _deploy/bin/$target
        chmod +x _deploy/bin/$target
    done
done

target=_debug_shell
echo "#!/bin/bash" > _deploy/bin/$target
echo "$_REAL_PATH_CMD" >> _deploy/bin/$target
echo "$_PRE_COMMAND" >> _deploy/bin/$target
echo "
if [[ -z \"\$SINGULARITY_NAME\" ]];then
    $_SHELL_CMD  \"\$@\" 
fi" >> _deploy/bin/$target
chmod +x _deploy/bin/$target

target=_debug_exec
echo "#!/bin/bash" > _deploy/bin/$target
echo "$_REAL_PATH_CMD" >> _deploy/bin/$target
echo "$_PRE_COMMAND" >> _deploy/bin/$target
echo "
if [[ -z \"\$SINGULARITY_NAME\" ]];then
    $_RUN_CMD \"\$@\" 
fi" >> _deploy/bin/$target
chmod +x _deploy/bin/$target


if [[ "$CW_ADD_LD" == "yes" && ${_SING_LIB_PATHS+defined} ]]; then
    echo "SINGULARITYENV_LD_LIBRARY_PATH=\"$(echo "${_SING_LIB_PATHS[@]}" | tr ' ' ':' ):\$SINGULARITYENV_LD_LIBRARY_PATH\"" >> _deploy/common.sh
fi
set +H
printf -- '%s\n' "SINGULARITYENV_LD_LIBRARY_PATH=\$(echo \$SINGULARITYENV_LD_LIBRARY_PATH | tr ':' '\n' | awk '!a[\$0]++' | tr '\n' ':')" >> _deploy/common.sh
printf -- '%s\n' "SINGULARITYENV_PATH=\$(echo \$SINGULARITYENV_PATH | tr ':' '\n' | awk '!a[\$0]++' | tr '\n' ':')" >> _deploy/common.sh
if [[ -f _extra_envs.sh ]];then
    cat _extra_envs.sh >> _deploy/common.sh 
fi
if [[ -f _extra_user_envs.sh ]];then
    cat _extra_user_envs.sh >> _deploy/common.sh 
fi
chmod o+r _deploy
chmod o+x _deploy
