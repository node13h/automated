#!/usr/bin/env bash

__DOC__='Release helper script'

set -euo pipefail

fail () {
    >&2 printf '%s\n' "$1"

    exit 1
}


usage () {
    >&2 cat <<EOF
${__DOC__}

${0} start|finish
EOF
    exit 1
}


start () {
    declare SEMVER_RE='^([0-9]+).([0-9]+).([0-9]+)(-([0-9A-Za-z.-]+))?(\+([0-9A-Za-z.-]))?$'

    declare version current_version major minor patch next_version

    git checkout develop

    version=$(cat VERSION)

    [[ "$version" =~ $SEMVER_RE ]]

    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"

    current_version="${major}.${minor}.${patch}"

    next_version="${major}.${minor}.$((patch+1))"
    printf '%s-SNAPSHOT\n' "$next_version" >VERSION

    git add VERSION

    git commit -m "Start ${next_version}"

    git checkout -b "release/${current_version}"

    printf '%s\n' "$current_version" >VERSION

    git add VERSION

    git commit -m "Start release ${next_version}"
}


finish () {
    declare current_version
    declare release_version
    declare release_branch
    declare git_user_name

    git_user_name=$(git config user.name)

    release_branch=$(git for-each-ref --format='%(refname:lstrip=2)' 'refs/heads/release/*')

    [[ -n "$release_branch" ]] || fail 'Release branch not found'

    git checkout master

    git merge -m "Merge ${release_branch}" "$release_branch"

    release_version=$(cat VERSION)

    git tag -a "$release_version" -m "Release ${release_version} by ${git_user_name}"

    git checkout develop

    current_version=$(cat VERSION)

    git merge -m "Merge master" master

    printf '%s\n' "$current_version" >VERSION

    git add VERSION

    git commit -m "Restore current version ${current_version}"

    git branch -d "$release_branch"
}


main () {
    case "${1:-}" in
        start)
            start
            ;;
        finish)
            finish
            ;;
        *)
            usage
            ;;
    esac
}


main "$@"
