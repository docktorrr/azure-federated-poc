#!/bin/sh

print_usage ()
{
 cat <<EOF
USAGE:
​
  ./local_build_push_notify.sh [options] IMAGE_NAME [TAG]
​
OPTIONS:
​
  -t, --token
      The token to pass into the authorization header. Will override the
      HUMANITEC_TOKEN environment variable if supplied.
​
  -o, --org
      The organization in Humanitec that the token belongs to.
​
  -h, --help
      Show this help text.
​
NOTES:
​
  IMAGE_NAME represents the full image name excluding the tag. It should include
  the registry and the repository. For example "registry.example.com/project/my-image".
​
  TAG is the tag for the image. If TAG is not provided, it will be set to the current commit SHA1.
​
  By default, the token will be read from the HUMANITEC_TOKEN environment
  variable.
​
EXAMPLE:
​
  ./local_build_push_notify.sh --org my-org registry.example.com/project/my-image 0.3.2-rc5
​
EOF
}

key_from_json_obj ()
{
 tr -d '\n' | sed 's/^[ \t\v\f]*{.*"'"${1}"'"[ \t\v\f]*:[ \t\v\f]*"\([^"]*\)"[ \t\v\f]*[,}].*$/\1/'
}

fetch_url ()
{
 method="$1"
 payload=""
 if [ "$method" = "POST" ] || [ "$method" = "PUT" ] || [ "$method" = "PATCH" ]
 then
  payload="$2"
  shift
 fi
 url="$2"
 auth_header="Authorization: Bearer ${HUMANITEC_TOKEN}"
 if command -v curl &> /dev/null
 then
  if [ "$payload" != "" ]
  then
   curl --fail -s \
    -X "$method" \
    -H "$auth_header" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$url"
  else
   curl --fail -s \
    -X "$method" \
    -H "$auth_header" \
    "$url"
  fi
     elif command -v wget &> /dev/null
 then
  if [ "$payload" != "" ]
  then
   wget --quiet -O - \
    --method="$method" \
    --header="$auth_header" \
    --header="Content-Type: application/json" \
    --body-data="$payload" \
    "$url"
  else
   wget --quiet -O - \
    --method="$method" \
    --header="$auth_header" \
    "$url"
  fi
 else
  echo "System does not have the commands wget or curl installed." >&2
  exit 1
 fi
}

api_prefix="https://dev-api.humanitec.io"

while (( $# ))
do
 case "$1" in
  '-t'|'--token')
   export HUMANITEC_TOKEN="$2"
   shift
   ;;
  '-o'|'--org')
   export HUMANITEC_ORG="$2"
   shift
   ;;
  '--api-prefix')
   api_prefix="$2"
   shift
   ;;
  '-h'|'--help')
   print_usage
   exit
   ;;
  *)
   image_name="$1"
   if [[ $2 == ""  ||  $2 == -* ]]
   then
    image_tag=""
    image_with_tag="${image_name}"
   else
    image_tag="$2"
    image_with_tag="${image_name}:${image_tag}"
    shift
   fi
 esac
 shift
done

if [ -z "${HUMANITEC_TOKEN}" ]
then
 echo "No token specified as option or via HUMANITEC_TOKEN environment variable." >&2
 exit 1
fi

if [ -z "$HUMANITEC_ORG" ]
then
 echo "No Organization specified as option or via HUMANITEC_ORG environment variable." >&2
 exit 1

fi

if [ -z "$image_with_tag" ]
then
 echo "No IMAGE_NAME provided." >&2
 exit 1
fi

echo "Retrieving registry credentials"
registry_json="$(fetch_url GET "${api_prefix}/orgs/${HUMANITEC_ORG}/registries/humanitec/creds")"
if [ $? -ne 0 ]
then
 echo "Unable to retrieve credentials for humanitec registry." >&2
 exit 1
fi

username="$(echo "$registry_json" | key_from_json_obj "username")"
password="$(echo "$registry_json" | key_from_json_obj "password")"
server="$(echo "$registry_json" | key_from_json_obj "registry")"

ref="$(git rev-parse --symbolic-full-name HEAD)"
commit="$(git rev-parse HEAD)"

if [ "$image_tag" = "" ]
then
 image_tag="$commit"
fi

echo "Logging into docker registry"
echo "${password}" | docker login -u "${username}" --password-stdin "${server}"
if [ $? -ne 0 ]
then
 echo "Unable to log into humanitec registry." >&2
 exit 1
fi

echo "Performing docker build"
local_tag="${HUMANITEC_ORG}/${image_name}:${image_tag}"
if ! docker build -t "$local_tag" .
then
 echo "Docker build failed." >&2
 exit 1
fi

remote_tag="${server}/$local_tag"
if ! docker tag "$local_tag" "$remote_tag"
then
 echo "Error pushing to remote registry: Cannot retag locally." >&2
 exit 1
fi

echo "Pushing image to registry: $remote_tag"
if ! docker push "$remote_tag"
then
 echo "Error pushing to remote registry: Push failed." >&2
 exit 1
fi

echo "Notifying Humanitec"
payload="{\"commit\":\"${commit}\",\"ref\":\"${ref}\",\"version\":\"${image_tag}\",\"name\":\"${image_name}\",\"type\":\"container\"}"
if ! fetch_url POST "$payload" "${api_prefix}/orgs/${HUMANITEC_ORG}/artefact-versions"
then
        echo "Unable to notify Humanitec." >&2
        exit 1
fi