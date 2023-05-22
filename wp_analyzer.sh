#!/bin/bash
# WordPress performance analyzer by Arto Simonyan

# Version #
ver="0.0.1"

# GLOBALS
wpDB=""
wpDBUser=""
wpDBPass=""
wpDBPrefix=""

# Time it takes to trigger a slowness warning in millseconds
timeTrigger=0.100

recommendSGOptimizer=false
recommendMemcache=false

scanURL=""

## COLORS ##
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD=$(tput bold)
NC='\033[0m'

echo -e "WordPress Performance analyzer v$ver by Arto Simonyan\n"

parseDatabaseDetails() {
    if [[ -f "wp-config.php" ]]; then
        wpDB=$(grep DB_NAME wp-config.php | awk -F "'" '{print $4}')
        wpDBUser=$(grep DB_USER wp-config.php | awk -F "'" '{print $4}')
        wpDBPass=$(grep DB_PASSWORD wp-config.php | awk -F "'" '{print $4}')
        wpDBPrefix=$(grep '$table_prefix' wp-config.php | awk -F "'" '{print $2}')
    else
        echo -e "\nWordPress config not found. Please run the script from the application's root"
        exit;
    fi
}

analyzeDatabase() {
    echo -e "${BOLD}---- [Analyzing Database] ----${NC}\n"

    wpDBSize=$(mysql -e "SELECT SUM(ROUND(((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024), 2)) AS '+' FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '$wpDB';" -u $wpDBUser -p$wpDBPass | grep -v +)
    echo -e "Size: $wpDBSize MB";

    wpRevisionsCount=$(mysql -e "use $wpDB; SELECT count(*) as '+' from "$wpDBPrefix"posts where post_type = 'revision'" -u $wpDBUser -p$wpDBPass | grep -v +)
    echo -e "Total post revisions: $wpRevisionsCount"

    wpTransientsCount=$(mysql -e "use $wpDB; SELECT COUNT(*) as '+' FROM "$wpDBPrefix"options WHERE option_name LIKE ('%\_transient\_%');" -u $wpDBUser -p$wpDBPass | grep -v +)
    echo -e "Total transients: $wpTransientsCount\n";

    wpShouldReduceDB=$(awk 'BEGIN{ print "500" < "'$wpDBSize'" }')
    if [ "$wpShouldReduceDB" -eq 1 ]; then
        echo -e "Database is larger than ${RED}500MB${NC}. Should consider reducing the size if possible.\n\n"
    fi
}

checkProfilerInstall() {
    echo -e "[>] Verifying that profiler is installed..."
    profilerPresent=$(wp package list | grep profile | awk '{print $1}')

    if [[ $profilerPresent = "wp-cli/profile-command" ]]; then
        echo -e "[+] Profiler package is installed.\n"
    else
        echo -e "Profiler package is missing, please install it before running the script.\nYou can use the following command to install it:\nwp package install wp-cli/profile-command\n"
        exit
    fi
}

checkSGOptimizer() {
    optimizerStatus=$(wp plugin list --skip-plugins --skip-themes | grep -i sg-cachepress | awk '{print $2}' )

    if [ "$optimizerStatus" = "active" ]; then echo "true"; else echo "false"; fi
}

checkDynamicCache() {

    pluginActive=$(checkSGOptimizer)

    if [ "$pluginActive" = "false" ]; then echo "false"; fi

    dynamicCacheEnabledInDB=$(wp option list --search='siteground_optimizer_enable_cache' --skip-plugins --skip-themes | grep -v -i 'option' | awk '{print $2}')
    
    if [ "$dynamicCacheEnabledInDB" = "1" ]; then
        echo -e "true"
    else
        echo -e "false"
    fi
}

checkMemcached() {
    
    if [ -f "wp-content/object-cache.php" ]; then
      
        if [ checkSGOptimizer = "true" ]; then
            
            ourDropin=$(grep 'Memcached Dropin for SGO' wp-content/object-cache.php)
            
            if [ "$ourDropin" = "Description: Memcached Dropin for SGO" ]; then

                memcachedEnabledInDB=$(wp option list --search='siteground_optimizer_enable_memcached' --skip-plugins --skip-themes | grep -v -i 'option' | awk '{print $2}')

                if [ "$memcachedEnabledInDB" = "1" ]; then
                    echo "true"  
                else
                    echo "false"
                fi
            fi
            
        else
            echo "false"
        fi
    else
        echo -e "false"
    fi
}

analyzeWordPress() {

    url=$1
    echo -e "${BOLD}---- [Analyzing the WordPress - $url] ----${NC}\n"

    #get the results and format them in a parsable state
    baseAnalysis=$(wp profile stage --url=$url --spotlight | awk '{print $1,$2}' | grep -v -i "stage time\|total")
    analysysArray=($(echo $baseAnalysis | tr " " "-" | sed 's/-/\n/2;P;D'))

    # declare some time variables we are going to use
    # main WordPress parts:
    bootstrap=0  #Plugins, themes, hooks etc
    main_query=0 #Mainly database stuff
    template=0 #The tempalte from the theme that will be loaded on the page. If no URL is provided that's the main page.

    # Slowest parts from the WordPress
    highest=""
    highestNumber=0

    for i in "${analysysArray[@]}"; 
    do 

    #Split the results in sector name/time for easy access
    sectorName=$(echo $i | awk -F "-" '{ print $1 }')
    sectorTime=$(echo $i | awk -F "-" '{ print $2 }' | sed 's/.$//')

    if [[ $sectorName = "bootstrap" ]]; then bootstrap=$sectorTime;
        elif [[ $sectorName = "main_query" ]]; then main_query=$sectorTime;
        else template=$sectorTime;
    fi

    #because we don't have the common sence to install a simple bc on our avalons ..... we use awk and more code
    calculationResult=$(awk 'BEGIN{ print "'$highestNumber'" < "'$sectorTime'" }')

    if [ "$calculationResult" -eq 1 ]; then
        highestNumber=$sectorTime
        highest=$sectorName
    fi
    done;

    #todo: malko po descriptive info
    echo -e "Bootstrap loading time - $bootstrap seconds.\nMain Query loading time - $main_query seconds.\nTemplate loading time - $template seconds.\n"
    #echo -e "\nSlowest loading part - $highest took $highestNumber to load.\n"

    if [[ $highest = "bootstrap" ]]; then
        echo -e "Slowest loading part of the site are the extensions (plugins/themes/addons) - ${RED}$highestNumber${NC} sec."

        pluginLoadTime=$(wp profile stage --all --spotlight --url=$url --fields=hook,time  | awk '{print $1, $2}' | grep -i plugins_loaded:before | grep -v -i 'muplugins' | awk '{ print $2 }' | sed 's/.$//')
        echo -e "The plugins took ${RED}$pluginLoadTime${NC} seconds to load."

    elif [[ $highest = "main_query" ]]; then
        echo -e "Slowest loading part of the site is the main query which suggests database related problems - ${RED}$highestNumber${NC} sec."
    else
        echo -e "Slowest loading part of the is the Theme's template which is used on the current page - ${RED}$highestNumber${NC} sec.\n"
    fi

    echo -e "\n${BOLD}---- [TOP 3 Slowest Extensions/Hooks] ----${NC}\n"

    hookResult=$(wp profile hook --all --spotlight --url=$url --orderby=DESC --fields=callback,location,time,cache_ratio | awk '{print $1,$2,$3,$4}' | grep -v -i 'callback\|total' | tr ' ' '*')
    hookArray=($(echo $hookResult | tr " " "\n"))

    iterations=0

    for x in "${hookArray[@]}"; 
    do

    if [ $iterations -eq 3 ]; then break; fi

    #echo $x;
    currentExtension=$(echo $x | awk -F '*' '{print $1}')
    currentExtensionExecutedFrom=$(echo $x | awk -F '*' '{print $2}')
    currentExtensionLoadTime=$(echo $x | awk -F '*' '{print $3}' | sed 's/.$//')
    currentExtensionCacheRaio=$(echo $x | awk -F '*' '{print $4}' | sed 's/.$//')

    echo -e "${BOLD}${GREEN}[$currentExtension]${NC} took ${RED}$currentExtensionLoadTime${NC} to load and was executed by the following script: ${GREEN}[$currentExtensionExecutedFrom]${NC}\n"

    #Check if plugin load time higher than the trigger
    calculationTimeTrigger=$(awk 'BEGIN{ print "'$timeTrigger'" < "'$currentExtensionLoadTime'" }')
    calculationCacheRatio=$(awk 'BEGIN{ print "65" < "'$currentExtensionCacheRaio'" }')

    memcachedStatus=$(checkMemcached)

    if [ "$calculationCacheRatio" -eq 1 ] && [ "$calculationTimeTrigger" -eq 1 ] && [ "$memcachedStatus" = "false" ]; then
         echo -e "Internal cache ratio is $currentExtensionCacheRaio and loading time is $currentExtensionLoadTime. Activating memcached should improve performance."
    fi

    let "iterations+=1"
    done

    echo -e "${BOLD}---- Checking SG Optimizer Cache Status ----${NC}\n"

    dynamicCacheStatus=$(checkDynamicCache)
    pluginStatus=$(checkSGOptimizer)

    if [ "$pluginStatus" = "true" ] && [ "$dynamicCacheStatus" = "false" ]; then
        echo -e "${BOLD}SG Optimizer plugin is active but dynamic cache is ${RED}not enabled${NC}."
    elif [ "$pluginStatus" = "false" ] && [ "dynamicCacheStatus" = "false" ]; then
        echo -e "${BOLD}SG Optimizer plugin isn't installed. You may recommend the client to install it.${NC}"
    else
        echo -e "${BOLD}SG Optimizer plugin is installed and dynamic cache is active.${NC}"
    fi
}

printHelp() {
    echo -e "Usage: sh wp_analyzer.sh <URL> [OPTIONAL ARGUMENTS]\n\n

    -h | --help - Will print help information.\n

    -url | --url | -u - Required argument. Supply the URL you want to analyze .\n

    --time | -t - The time trigger to mark a extension as slow. By default this is set to 0.1 seconds. Anything above that is considered slow.\n
    "
}

if [ $# -eq 0 ]; then
    printHelp
    exit
fi

#parse arguments
for i in "$@"; do
    case $i in 
        --h|help|-h|--help)
    printHelp
    exit
    shift
    ;;

    --url|-url|-u)
    shift
    scanURL=$1
    shift
    ;;
    
    --time|-t)
    shift
    timeTrigger=$1
    shift
    ;;

    *) # all other arguments (invalid ones)
    ;;
    esac
done


#Check if the required prerequisetes are present
checkProfilerInstall

# Gather the database details for analysys
parseDatabaseDetails
analyzeDatabase
analyzeWordPress $scanURL
