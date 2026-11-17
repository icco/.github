#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

owner="${OWNER:-icco}"
assignee="${ASSIGNEE:-icco}"
reviewer="copilot-pull-request-reviewer"
dry_run="${DRY_RUN:-}"

run() {
  if [ -n "$dry_run" ]; then
    echo "dry run: $*"
  else
    "$@" >/dev/null
  fi
}

assignee_id=$(gh api graphql -H "X-Github-Next-Global-ID: 1" -f login="$assignee" -f query='query($login:String!){user(login:$login){id}}' --jq .data.user.id)

prs=$(gh api graphql --paginate \
  -f q="is:pr is:open archived:false user:$owner" \
  -f query='query($q:String!,$endCursor:String){search(query:$q,type:ISSUE,first:50,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{... on PullRequest{id url assignees(first:20){nodes{login}} reviewRequests(first:20){nodes{requestedReviewer{... on Bot{login}}}} reviews(first:100){nodes{author{login}}}}}}}' \
  --jq '.data.search.nodes[]')

failed=0
while IFS= read -r pr; do
  [ -n "$pr" ] || continue
  id=$(jq -r .id <<<"$pr")
  url=$(jq -r .url <<<"$pr")

  if ! jq -e --arg a "$assignee" 'any(.assignees.nodes[]; .login == $a)' <<<"$pr" >/dev/null; then
    echo "assign $assignee: $url"
    run gh api graphql -f id="$id" -f user="$assignee_id" \
      -f query='mutation($id:ID!,$user:ID!){addAssigneesToAssignable(input:{assignableId:$id,assigneeIds:[$user]}){clientMutationId}}' \
      || { echo "::error::assign failed: $url"; failed=1; }
  fi

  if ! jq -e --arg r "$reviewer" 'any(.reviewRequests.nodes[]; .requestedReviewer.login? == $r) or any(.reviews.nodes[]; .author.login? == $r)' <<<"$pr" >/dev/null; then
    echo "request copilot review: $url"
    run gh api graphql -f id="$id" -f bot="$reviewer" \
      -f query='mutation($id:ID!,$bot:String!){requestReviewsByLogin(input:{pullRequestId:$id,botLogins:[$bot],union:true}){clientMutationId}}' \
      || { echo "::error::review request failed: $url"; failed=1; }
  fi
done <<<"$prs"

exit "$failed"
