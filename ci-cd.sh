#!/bin/bash

# One script to rule them all!
# This script is used to deploy a service to Kubernetes.
# Currently supports Java & Python services.
# Usage : ./deploy.sh --k8s-service-name=<name> --namespace=<name> --module-name=<name>



#The below function is used to set and validate the command line options.
#k8s_service_name:
#  - would be the name of the service in kubernetes.
#  - this name would be used to create the deployment, service and hpa in kubernetes.
#  - For ex, if the k8s_service_name is "my-service", then the deployment name would be "my-service-deployment", service name would be "my-service-service" and hpa name would be "my-service-hpa".
#  - this name would also be used to create the docker image name, tag.
#namespace:
#  - would be the namespace in which the service is deployed.
#  - namespace values would be staging, prod, prod-replica, prod-worker.
#module_name:
#  - would be the name of the module that you want to deploy. If you have a multi module project, this parameter can be specified to deploy a specific module. If you have a single module project, then you can pass '/'.
set_and_validate_cmd_line_options () {
  # Default values
  k8s_service_name=""
  namespace=""
  module_name=""

  # Parse command-line options
  for arg in "$@"; do
      case "$arg" in
          --k8s-service-name=*)
              k8s_service_name="${arg#*=}"
              ;;
          --namespace=*)
              namespace="${arg#*=}"
              ;;
          --module-name=*)
              module_name="${arg#*=}"
              ;;
          *)
              echo "Invalid option: $arg" >&2
              exit 1
              ;;
      esac
  done

  # Validate the field values
  if [ -z "$k8s_service_name" ] || [ -z "$namespace" ] || [ -z "$module_name" ]; then
      echo "Three fields are required. Usage: script.sh --k8s-service-name=<name> --namespace=<name> --module-name=<name>"
      exit 1
  fi

  # Output the field values
  echo "Kubernetes Service Name: $k8s_service_name"
  echo "Namespace: $namespace"
  echo "Module Name: $module_name"
}

determine_programming_lang () {
  if [ -f "${WORKSPACE}${module_name}build.gradle" ]; then
      echo "Java lang detected"
      CODE_LANG=java
  elif [ -f "${WORKSPACE}${module_name}requirements.txt" ]; then
      echo "Python lang detected"
      CODE_LANG=python
  else
      die "failed to determine code language"
  fi
}

# The below function is used to set the server config file path.
# server-config file in your repo will be used to control the number of resources of the deployment & any other additional server configurations.
set_server_config () {
  if [ "$CODE_LANG" = "java"  ]; then
    SERVER_CONFIG="${WORKSPACE}${module_name}src/main/resources/server-config.yml"
    echo "Server config file for java: $SERVER_CONFIG"
  elif [ "$CODE_LANG" = "python" ]; then
    SERVER_CONFIG="${WORKSPACE}${module_name}server-config.yml"
    echo "Server config file for python: $SERVER_CONFIG"
  else
    die "failed to determine server config file"
  fi
}

# Use this function to initialise any variables that are required later for the deployment.
set_init_vars () {
  # validate namespace
  if [[ "${namespace}" != "prod" && "${namespace}" != "prod-replica" && "${namespace}" != "staging" && "${namespace}" != "prod-worker" ]]; then
    echo "Invalid namespace. Must be one of 'prod', 'prod-replica', 'prod-worker' or 'staging'."
    exit 1
  fi

  #set kubernetes context
  if [ "${namespace}" = 'prod' ] || [ "${namespace}" = 'prod-replica' ] || [ "${namespace}" = 'prod-worker' ]
  then
      k8sContext=prod
  elif [ "${namespace}" = 'staging' ]
  then
      k8sContext=staging
  fi
  echo "Kubernetes Context: $k8sContext"

  awsAccountId=1234567890
  echo "AWS Account Id: $awsAccountId"
}

# This function initialise Kubernetes fields. This function is used to resolve variables that are used as placeholders in the yaml files.
# Use set_init_vars to initialise any common variables used in this script.
init_K8s_fields() {
  portPlaceholder=$(yq ".server.port" "$SERVER_CONFIG" )
  if [ -z "$portPlaceholder" ] || [ "$portPlaceholder" = "null" ]; then
      echo "server.port not found in server-config.yml"
      exit 1
  fi
  echo "port: $portPlaceholder"

  cpuPlaceholder=$(yq ".dcos.env.${namespace}.deploymentSpec.cpu" "$SERVER_CONFIG" )
  if [ -z "$cpuPlaceholder" ] || [ "$cpuPlaceholder" = "null" ]; then
      echo "cpu not found in server-config.yml"
      exit 1
  fi
  echo "CPU: $cpuPlaceholder"

  memPlaceholder=$(yq ".dcos.env.${namespace}.deploymentSpec.mem" "$SERVER_CONFIG" )
  if [ -z "$memPlaceholder" ] || [ "$memPlaceholder" = "null" ]; then
      echo "mem not found in server-config.yml"
      exit 1
  fi
  echo "mem: $memPlaceholder"

  cpuLimitPlaceholder=$(yq ".dcos.env.${namespace}.deploymentSpec.cpuLimit" "$SERVER_CONFIG" )
  if [ -z "$cpuLimitPlaceholder" ] || [ "$cpuLimitPlaceholder" = "null" ]; then
      echo "cpu limit not found in server-config.yml. Using default value"
      cpuLimitPlaceholder=2000m
  fi
  echo "CPU Limit: $cpuLimitPlaceholder"

  memLimitPlaceholder=$(yq ".dcos.env.${namespace}.deploymentSpec.memLimit" "$SERVER_CONFIG" )
  if [ -z "$memLimitPlaceholder" ] || [ "$memLimitPlaceholder" = "null" ]; then
      echo "mem limit not found in server-config.yml. Using default value"
      memLimitPlaceholder=4096Mi
  fi
  echo "mem Limit: $memLimitPlaceholder"

  instancesPlaceholder=$(yq ".dcos.env.${namespace}.deploymentSpec.instances" "$SERVER_CONFIG" )
  if [ -z "$instancesPlaceholder" ] || [ "$instancesPlaceholder" = "null" ]; then
      echo "instances not found in server-config.yml"
      exit 1
  fi
  echo "instances: $instancesPlaceholder"

  maxReplicasPlaceholder=$(yq ".dcos.env.${namespace}.hpaSpec.maxReplicas" "$SERVER_CONFIG" )
  if [ -z "$maxReplicasPlaceholder" ] || [ "$maxReplicasPlaceholder" = "null" ]; then
      echo "maxReplicas not found in server-config.yml"
      exit 1
  fi
  echo "maxReplicas: $maxReplicasPlaceholder"

  minReplicasPlaceholder=$(yq ".dcos.env.${namespace}.hpaSpec.minReplicas" "$SERVER_CONFIG" )
  if [ -z "$minReplicasPlaceholder" ] || [ "$minReplicasPlaceholder" = "null" ]; then
      echo  "minReplicas not found in server-config.yml"
      exit 1
  fi
  echo "minReplicas: $minReplicasPlaceholder"
}

create_docker_file () {
    case $CODE_LANG in
        java) create_java_docker_file ;;
        python) create_python_docker_file ;;
        *) die "unrecognized language to create dockerfile" ;;
    esac
}

create_java_docker_file () {
  echo "creating Java Dockerfile"
  echo "FROM awsAccountId.dkr.ecr.ap-south-1.amazonaws.com/image-name:skywalking-java-agent" > beast-k8s/Dockerfile
  echo "COPY *SNAPSHOT.jar app.jar" >> beast-k8s/Dockerfile
  echo "EXPOSE 5000" >> beast-k8s/Dockerfile
  echo "CMD [\"java\", \"-javaagent:skywalking/skywalking-agent.jar=agent.namespace=${namespace},collector.backend_service=172.31.120.217:11800,plugin.jdbc.trace_sql_parameters=true,profile.active=true\", \"-jar\", \"app.jar\"]" >> beast-k8s/Dockerfile
  echo "Replacing names in dockerfile"
  sed -i "s/awsAccountId/${awsAccountId}/g" beast-k8s/Dockerfile
  sed -i "s/image-name/jar-docker-images/g" beast-k8s/Dockerfile
}

create_python_docker_file () {
  echo "creating Python Dockerfile"
  echo "FROM python:3.11" > beast-k8s/Dockerfile
  echo "WORKDIR /app" >> beast-k8s/Dockerfile
  echo "ENV HOST '0.0.0.0'" >> beast-k8s/Dockerfile
  echo "COPY requirements.txt requirements.txt" >> beast-k8s/Dockerfile
  echo "RUN pip3 install -r requirements.txt" >> beast-k8s/Dockerfile
  echo "COPY . ." >> beast-k8s/Dockerfile
  echo "CMD [\"python3\", \"main.py\"]" >> beast-k8s/Dockerfile
}

push_docker_image_to_ECR () {
  echo "login to ECR and if Repository is not available it will create"
  aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin ${awsAccountId}.dkr.ecr.ap-south-1.amazonaws.com
  aws ecr describe-repositories --region ap-south-1 --repository-names "${k8s_service_name}" || aws ecr create-repository --region ap-south-1 --repository-name "${k8s_service_name}"

  echo "creating docker build and pushing to the ECR"

  if [ "$CODE_LANG" = "java" ]; then
    echo "docker build for java"
    docker build -t "${k8s_service_name}":${BUILD_NUMBER} -f beast-k8s/Dockerfile ${WORKSPACE}"${module_name}"build/libs
  elif [ "$CODE_LANG" = "python" ]; then
    echo "docker build for python"
    docker build -t "${k8s_service_name}":${BUILD_NUMBER} -f beast-k8s/Dockerfile .
  else
    die "unrecognized language to docker build"
  fi
  docker tag "${k8s_service_name}":${BUILD_NUMBER} ${awsAccountId}.dkr.ecr.ap-south-1.amazonaws.com/"${k8s_service_name}":"${k8s_service_name}"-${BUILD_NUMBER}
  docker push ${awsAccountId}.dkr.ecr.ap-south-1.amazonaws.com/"${k8s_service_name}":"${k8s_service_name}"-${BUILD_NUMBER}
  docker rmi ${awsAccountId}.dkr.ecr.ap-south-1.amazonaws.com/"${k8s_service_name}":"${k8s_service_name}"-${BUILD_NUMBER}
  docker rmi "${k8s_service_name}":${BUILD_NUMBER}
}

deploy_to_k8s () {
  echo "Replacing the names"
  sed -i "s|application-name|"${k8s_service_name}"|g" beast-k8s/common/deployment/$apiYamlFile
  sed -i "s|aws-ecr-image-tag|"${k8s_service_name}"-${BUILD_NUMBER}|g" beast-k8s/common/deployment/$apiYamlFile
  sed -i "s|namespace-name|"${namespace}"|g" beast-k8s/common/deployment/$apiYamlFile
  sed -i "s|aws-account-id|"${awsAccountId}"|g" beast-k8s/common/deployment/$apiYamlFile
  sed -i "s|cpuPlaceholder|"${cpuPlaceholder}"|g" beast-k8s/common/deployment/$apiYamlFile
  sed -i "s|cpuLimitPlaceholder|"${cpuLimitPlaceholder}"|g" beast-k8s/common/deployment/$apiYamlFile
  sed -i "s|memPlaceholder|"${memPlaceholder}"|g" beast-k8s/common/deployment/$apiYamlFile
  sed -i "s|memLimitPlaceholder|"${memLimitPlaceholder}"|g" beast-k8s/common/deployment/$apiYamlFile
  sed -i "s|instancesPlaceholder|"${instancesPlaceholder}"|g" beast-k8s/common/deployment/$apiYamlFile
  sed -i "s|maxReplicasPlaceholder|"${maxReplicasPlaceholder}"|g" beast-k8s/common/deployment/$apiYamlFile
  sed -i "s|minReplicasPlaceholder|"${minReplicasPlaceholder}"|g" beast-k8s/common/deployment/$apiYamlFile
  sed -i "s|portPlaceholder|"${portPlaceholder}"|g" beast-k8s/common/deployment/$apiYamlFile

  echo "deploying api to eks-cluster"
  kubectl --context=${k8sContext} apply -f beast-k8s/common/deployment/$apiYamlFile
}


# main
# script starts here. Any other functionality required can be added below as a function call at the appropriate place.
set_and_validate_cmd_line_options "$@"
determine_programming_lang
set_server_config
set_init_vars

create_docker_file
push_docker_image_to_ECR
init_K8s_fields

#get deployment yaml file name
if [ "${k8s_service_name}" = 'api' ]
then
  echo "name of deploying file"
  if [ "${namespace}" = 'prod' ]
  then
    apiYamlFile=prod-api.yaml
  elif [ "${namespace}" = 'prod-replica' ]
  then
    apiYamlFile=prod-replica-api.yaml
  elif [ "${namespace}" = 'prod-worker' ]
  then
    apiYamlFile=prod-worker-api.yaml
  elif [ "${namespace}" = 'staging' ]
  then
    apiYamlFile=staging-api.yaml
  fi
else
  apiYamlFile=eks-deployment.yaml
fi

deploy_to_k8s
