'use strict';

// Only a confirmed PR for this exact pushed head can replace push checks.
async function shouldRunChecks({ github, context, warning, info }) {
    const branchPrefix = 'refs/heads/';
    if (context.eventName !== 'push' || !context.ref.startsWith(branchPrefix)) {
        return true;
    }
    const { owner, repo } = context.repo;
    const repository = `${owner}/${repo}`.toLowerCase();
    const branch = context.ref.slice(branchPrefix.length);
    const isSamePushedHead = pullRequest =>
        pullRequest?.state === 'open' &&
        pullRequest.head?.repo?.full_name?.toLowerCase() === repository &&
        pullRequest.head?.ref === branch &&
        pullRequest.head?.sha === context.sha;

    try {
        const pullRequests = await github.paginate(github.rest.pulls.list, {
            owner, repo, state: 'open', head: `${owner}:${branch}`, per_page: 100
        });
        for (const pullRequest of pullRequests.filter(isSamePushedHead)) {
            const { data: current } = await github.rest.pulls.get({
                owner, repo, pull_number: pullRequest.number
            });
            // Conflicted PRs do not start pull_request workflows. Unknown
            // mergeability or a changed head must leave push checks enabled.
            if (isSamePushedHead(current) && current.mergeable === true) {
                info(`Push checks are covered by pull request #${current.number} for the same head.`);
                return false;
            }
        }
    } catch {
        // Do not turn an API outage or a read-permission failure into no tests.
        warning('Could not confirm equivalent PR checks; running all push checks.');
    }
    return true;
}

module.exports = { shouldRunChecks };
