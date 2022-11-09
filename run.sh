#!/bin/bash
#########################################################
# Run hello bench for OCI nydus optimized-nydus image.  #
# Platform :All Linux Based Platform                    #
# Version  :1.0                                         #
# Date     :2022-11-09                                  #
# Author   :Bin Tang                                    #
# Contact  :tangbin.bin@bytedance.com                   #
#########################################################

#########################################################
# No need to modify
#########################################################
CURRENT_ROUND=1
RESULT_FILE=result.txt
RESULT_CSV=result.csv
NYDUSIFY_BIN=$(which nydusify)
NYDUS_IMAGE_BIN=$(which nydus-image)
CTR_REMOTE_BIN=$(which ctr-remote)

#########################################################
# Could alert value via arguments
#########################################################
ROUND_NUM=10
RESULT_DIR=data.1
OPTIMIZE_BIN=$(pwd)/optimize-bin
SOURCE_REGISTRY=docker.io/library
TARGET_REGISTRY=""
SKIP=false
IMAGES_PATH=hello_bench_image_list.txt

#########################################################
# Push OCI image to TARGET_REGISTRY
# Globals:
#   TARGET_REGISTRY
# Arguments:
#   image
# Returns:
#   None
#########################################################
function push_registry() {
    image=$1
    echo "[INFO] Pushing ${image} to ${TARGET_REGISTRY}/${image}"

    sudo docker pull ${image}
    sudo docker tag ${SOURCE_REGISTRY}/${image} ${TARGET_REGISTRY}/${image}
    sudo docker push ${TARGET_REGISTRY}/${image}
    sudo docker rmi -f ${TARGET_REGISTRY}/${image}
    sudo docker rmi -f ${image}
}

#########################################################
# Convert OCI image to nydus/stargz image and push to 
# TARGET_REGISTRY
# Globals:
#   TARGET_REGISTRY
# Arguments:
#   image
# Returns:
#   None
#########################################################
function convert() {
    image=$1

    sudo nerdctl pull ${TARGET_REGISTRY}/${image}
    echo "[INFO] Converting ${TARGET_REGISTRY}/${image} to ${TARGET_REGISTRY}/${image}:nydusv6 ..."
    echo "sudo $NYDUSIFY_BIN convert \
        --fs-version 6 \
        --nydus-image $NYDUS_IMAGE_BIN \
        --source ${TARGET_REGISTRY}/${image} \
        --target ${TARGET_REGISTRY}/${image}:nydusv6"
    sudo $NYDUSIFY_BIN convert \
        --fs-version 6 \
        --nydus-image $NYDUS_IMAGE_BIN \
        --source ${TARGET_REGISTRY}/${image} \
        --target ${TARGET_REGISTRY}/${image}:nydusv6
    if [ "${${CTR_REMOTE_BIN}}" != "" ]; then
        echo "[INFO] Converting ${TARGET_REGISTRY}/${image} to ${TARGET_REGISTRY}/${image}:stargz ..."
        sudo ${CTR_REMOTE_BIN} image optimize \
            --oci \
            --no-optimize \
            ${TARGET_REGISTRY}/${image}:latest ${TARGET_REGISTRY}/${image}:stargz
        sudo nerdctl push ${TARGET_REGISTRY}/${image}:stargz
    fi
}

#########################################################
# Convert OCI image to nydus image with optimization and
# push to TARGET_REGISTRY
# Globals:
#   TARGET_REGISTRY
# Arguments:
#   image
# Returns:
#   None
#########################################################
function convert_with_optimize() {
    image=$1

    sudo nerdctl pull ${TARGET_REGISTRY}/${image}
    echo "[INFO] Convert ${TARGET_REGISTRY}/${image} to ${TARGET_REGISTRY}/${image}:optimized-nydusv6 ..."
    sudo $NYDUSIFY_BIN convert \
        --fs-version 6 \
        --nydus-image $NYDUS_IMAGE_BIN \
        --source ${TARGET_REGISTRY}/${image} \
        --prefetch-patterns \
        --target ${TARGET_REGISTRY}/${image}:optimized-nydusv6 <accessed_files/${image}.txt
}

#########################################################
# Stop all running containers
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#########################################################
function stop_all_containers {
    containers=$(sudo nerdctl ps -q | tr '\n' ' ')
    if [[ ${containers} == "" ]]; then
        return 0
    else
        echo "Killing containers ${containers}"
        for C in ${containers}; do
            sudo nerdctl kill "${C}"
            sudo nerdctl stop "${C}"
            sudo nerdctl rm "${C}"
        done
        return 1
    fi
}

#########################################################
# Run hello bench for OCI image, nydus image and
# optimized-nydus image
# Globals:
#   TARGET_REGISTRY
# Arguments:
#   image
# Returns:
#   None
#########################################################
function run() {
    image=$1

    stop_all_containers
    sudo nerdctl ps -a | awk 'NR>1 {print $1}' | xargs sudo nerdctl rm >/dev/null 2>&1
    sudo nerdctl container prune -f
    sudo nerdctl image prune -f --all
    sudo systemctl restart nydus-snapshotter
    sleep 1

    echo "[INFO] Run hello bench in ${image} ..."
    sudo nerdctl --snapshotter overlayfs rmi -f ${TARGET_REGISTRY}/${image} >/dev/null 2>&1
    result=$(sudo ./hello.py --engine nerdctl --snapshotter overlayfs --op run \
        --registry=${TARGET_REGISTRY} \
        --images ${image} |
        grep "repo")
    echo ${result}
    echo ${result} >>${RESULT_DIR}/${RESULT_FILE}.${CURRENT_ROUND}
    echo "[INFO] Remove image ${TARGET_REGISTRY}/${image} ..."
    sudo nerdctl --snapshotter overlayfs rmi -f ${TARGET_REGISTRY}/${image} >/dev/null 2>&1

    echo "[INFO] Run hello bench in ${image}:nydusv6 ..."
    sudo nerdctl --snapshotter nydus rmi -f ${TARGET_REGISTRY}/${image}:nydusv6 >/dev/null 2>&1
    result=$(sudo ./hello.py --engine nerdctl --snapshotter nydus --op run \
        --registry=${TARGET_REGISTRY} \
        --images ${image}:nydusv6 |
        grep "repo")
    echo ${result}
    echo ${result} >>${RESULT_DIR}/${RESULT_FILE}.${CURRENT_ROUND}
    echo "[INFO] Remove image ${TARGET_REGISTRY}/${image}:nydusv6 ..."
    sudo nerdctl --snapshotter nydus rmi -f ${TARGET_REGISTRY}/${image}:nydusv6 >/dev/null 2>&1

    echo "[INFO] Run hello bench in ${image}:optimized-nydusv6 ..."
    sudo nerdctl --snapshotter nydus rmi -f ${TARGET_REGISTRY}/${image}:optimized-nydusv6 >/dev/null 2>&1
    result=$(sudo ./hello.py --engine nerdctl --snapshotter nydus --op run \
        --registry=${TARGET_REGISTRY} \
        --images ${image}:optimized-nydusv6 |
        grep "repo")
    echo ${result}
    echo ${result} >>${RESULT_DIR}/${RESULT_FILE}.${CURRENT_ROUND}
    echo "[INFO] Remove image ${TARGET_REGISTRY}/${image}:optimized-nydusv6 ..."
    sudo nerdctl --snapshotter nydus rmi -f ${TARGET_REGISTRY}/${image}:optimized-nydusv6 >/dev/null 2>&1

    echo "[INFO] Run hello bench in ${image}:stargz ..."
    sudo nerdctl --snapshotter stargz rmi -f ${TARGET_REGISTRY}/${image}:stargz >/dev/null 2>&1
    result=$(sudo ./hello.py --engine nerdctl --snapshotter stargz --op run \
        --registry=${TARGET_REGISTRY} \
        --images ${image}:stargz |
        grep "repo")
    echo ${result}
    echo ${result} >>${RESULT_DIR}/${RESULT_FILE}.${CURRENT_ROUND}
    echo "[INFO] Remove image ${TARGET_REGISTRY}/${image}:stargz ..."
    sudo nerdctl --snapshotter stargz rmi -f ${TARGET_REGISTRY}/${image}:stargz >/dev/null 2>&1
}

#########################################################
# Get accessed files list for workload and convert to
# nydus image with optimization
# Globals:
#   TARGET_REGISTRY
# Arguments:
#   image
# Returns:
#   None
#########################################################
function optimize() {
    image=$1

    sudo nerdctl --snapshotter overlayfs pull ${TARGET_REGISTRY}/${image}
    echo "[INFO] Optimizing image ${image}"
    sudo ./hello.py --optimize=True \
        --optimize-bin=${OPTIMIZE_BIN} \
        --target-registry=${TARGET_REGISTRY} \
        --registry=${TARGET_REGISTRY} \
        --images ${image}

    convert_with_optimize ${image}
}

#########################################################
# Handle data in $RESULT_DIR to csv and png
# Globals:
#   RESULT_DIR
# Arguments:
#   None
# Returns:
#   None
#########################################################
function handle_data() {
    python3_path=$(which python3)
    if [ "$(which python3)" == "" ]; then
        echo "[ERROR] Can not found python3"
        exit
    fi
    if [ ! -d ${RESULT_DIR} ]; then
        echo "[ERROR] Directory ${RESULT_DIR} not exist"
        exit
    fi
    ${python3_path} draw.py -d ${RESULT_DIR} -r result
}

#########################################################
# Check required options for this script
# Globals:
#   TARGET_REGISTRY

#   SOURCE_REGISTRY
# Arguments:
#   None
# Returns:
#   None
#########################################################
function check_opts() {
    if [ "${TARGET_REGISTRY}" == "" ]; then
        echo "[ERROR] TARGET_REGISTRY is null"
        exit
    fi
    if [ "${SOURCE_REGISTRY}" == "" ]; then
        echo "[ERROR] SOURCE_REGISTRY is null"
        exit
    fi
}

#########################################################
# Usage information
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#########################################################
function usage() {
    echo "Usage:"
    echo -e "run.sh \t[-o operation] \t\t[-i images] \t\t\t[-p images path] \t[-s source registry] \t[-t target registry]
       \t[-r target repository] \t[-b optimize binary path] \t[-n round number] \t[-d result directory] \t[-k skip finished test]"
    echo ""
    echo "Description:"
    echo -e "operation, \t\tavailable options are [ push convert optimize run all draw ]"
    echo -e "images, \t\timages list"
    echo -e "images path, \t\tfile path that contains images list (line by line)"
    echo -e "source registry, \tsource registry for pulling image"
    echo -e "target registry, \target registry for pushing image"
    echo -e "target repository, \ttarget repository, follow behind target repository"
    echo -e "optimize binary path, \toptimize binary path for optimizing nydus image"
    echo -e "round number, \t\tnumber of round to run hellobench"
    echo -e "result directory, \tdirectory to store raw result data"
    echo -e "skip finished test, \tskip images that already finisned (in \$RESULT_DIR/\$RESULT_FILE)"
    exit -1
}

function getopts_extra() {
    declare i=1
    while [[ ${OPTIND} -le $# && ${!OPTIND:0:1} != '-' ]]; do
        OPTARG[i]=${!OPTIND}
        let i++ OPTIND++
    done
}

available_operation="push convert optimize run all draw"

if [ $# -eq 0 ]; then
    usage
fi

while getopts o:i:p:s:t:r:b:n:d:kh OPT; do
    case $OPT in
    o)
        operation=${OPTARG}
        if ! [[ "$available_operation" =~ "$operation" ]]; then
            echo "operation ${operation} not support now"
            exit
        fi

        ;;
    i)
        getopts_extra "$@"
        images=("${OPTARG[@]}")
        ;;
    p)
        IMAGES_PATH=${OPTARG}
        ;;
    s)
        SOURCE_REGISTRY=${OPTARG}
        ;;
    t)
        TARGET_REGISTRY=${OPTARG}
        ;;
    b)
        OPTIMIZE_BIN=${OPTARG}
        ;;
    n)
        ROUND_NUM=${OPTARG}
        ;;
    d)
        RESULT_DIR=${OPTARG}
        ;;
    k)
        SKIP=true
        ;;
    *)
        usage
        ;;
    esac
done
shift $((OPTIND - 1))

if [ ${#images[@]} -gt 0 ]; then
    IMAGES=()
    for image in "${images[@]}"; do
        IMAGES+=($image)
    done
else
    IMAGES=($(cat ${IMAGES_PATH} | tr "\n" " "))
fi

images_length=${#IMAGES[@]}
echo "images:"
for IMAGE in "${IMAGES[@]}"; do
    echo "- ${IMAGE}"
done

if [ ${images_length} -eq 0 ] && [ "$IMAGES_PATH" == "" ]; then
    echo "both images list and file path are null"
    exit
fi

case $operation in
push)
    check_opts
    for image in "${IMAGES[@]}"; do
        push_registry ${image}
    done
    ;;
convert)
    check_opts
    for image in "${IMAGES[@]}"; do
        convert ${image}
    done
    ;;
optimize)
    check_opts
    if [ "${OPTIMIZE_BIN}" == "" ]; then
        echo "[ERROR] OPTIMIZE_BIN is null"
        exit
    fi
    for image in "${IMAGES[@]}"; do
        optimize ${image}
    done
    ;;
run)
    check_opts
    if [ "${OPTIMIZE_BIN}" == "" ]; then
        echo "[ERROR] OPTIMIZE_BIN is null"
        exit
    fi
    if [ ! "${SKIP}" == "true" ]; then
        if [ -d ${RESULT_DIR} ]; then
            rm -rf ${RESULT_DIR}
        fi
        mkdir ${RESULT_DIR}
    fi
    for i in $(seq 1 ${ROUND_NUM}); do
        CURRENT_ROUND=${i}
        if [ ! "${SKIP}" == "true" ]; then
            echo "" >${RESULT_DIR}/${RESULT_FILE}.${CURRENT_ROUND}
        fi

        for image in "${IMAGES[@]}"; do
            if [ "${SKIP}" == "true" ]; then
                skip=false
                for i in $(cat ${RESULT_DIR}/${RESULT_FILE}.${CURRENT_ROUND}); do
                    if [[ "${i}" =~ "${image}" ]]; then
                        echo "Skip image ${image}."
                        skip=true
                        break
                    fi
                done
                if [ "${skip}" == "true" ]; then
                    continue
                fi
            fi
            run ${image}
        done
    done
    ;;
all)
    check_opts
    if [ ! "${SKIP}" == "true" ]; then
        if [ -d ${RESULT_DIR} ]; then
            rm -rf ${RESULT_DIR}
        fi
        mkdir ${RESULT_DIR}
    fi
    for i in $(seq 1 ${ROUND_NUM}); do
        CURRENT_ROUND=${i}
        if [ ! "${SKIP}" == "true" ]; then
            echo "" >${RESULT_DIR}/${RESULT_FILE}.${CURRENT_ROUND}
        fi

        for image in "${IMAGES[@]}"; do
            if [ "${SKIP}" == "true" ]; then
                skip=false
                for i in $(cat ${RESULT_DIR}/${RESULT_FILE}.${CURRENT_ROUND}); do
                    if [[ "${i}" =~ "${image}" ]]; then
                        echo "Skip image ${image}."
                        skip=true
                        break
                    fi
                done
                if [ "${skip}" == "true" ]; then
                    continue
                fi
            fi
            if [ ${CURRENT_ROUND} -eq 1 ]; then
                push_registry ${image}
                convert ${image}
                optimize ${image}
            fi
            run ${image}
        done
    done

    handle_data
    ;;
draw)
    handle_data
    ;;
*)
    echo "get invalid operation: ${operation}"
    usage
    exit
    ;;
esac
