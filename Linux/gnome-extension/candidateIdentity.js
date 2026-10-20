// JSON object member order is not candidate identity. Swift's encoder may
// reorder nested dictionaries between otherwise equivalent snapshots.
export function serializeCandidateIdentity(value) {
    return JSON.stringify(value, (_key, item) => {
        if (item === null || typeof item !== 'object' || Array.isArray(item)) return item;
        return Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]]));
    });
}
