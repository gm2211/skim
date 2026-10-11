/**
 * The default order a site lists AI services in, and which ones it should mark as not
 * recommended. Sites inherit this and can pass their own order instead.
 *
 * Services whose subscriptions a buyer can actually use from a site come first. Claude comes last
 * because Anthropic doesn't allow its subscriptions in third-party apps (see claude.ts).
 */
export type ServiceKey = 'grok' | 'chatgpt' | 'openrouter' | 'claude';

export const DEFAULT_SERVICE_ORDER: readonly ServiceKey[] = ['grok', 'chatgpt', 'openrouter', 'claude'];

/** Why a service is listed but not recommended; absent means recommended. */
export const NOT_RECOMMENDED_REASON: Partial<Record<ServiceKey, string>> = {
  claude: "Anthropic doesn't allow subscriptions in other apps.",
};

/** Sorts `items` by `order`; items whose key is not in `order` keep their relative place at the end. */
export function orderServices<T>(items: readonly T[], keyOf: (item: T) => ServiceKey | undefined, order: readonly ServiceKey[] = DEFAULT_SERVICE_ORDER): T[] {
  const rank = (item: T) => {
    const key = keyOf(item);
    const index = key ? order.indexOf(key) : -1;
    return index === -1 ? order.length : index;
  };
  return items.map((item, index) => ({ item, index })).sort((a, b) => rank(a.item) - rank(b.item) || a.index - b.index).map(entry => entry.item);
}
