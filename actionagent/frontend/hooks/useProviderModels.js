import { useEffect, useState } from 'react';
import { FALLBACK_PROVIDER_MODELS, fetchProviderModels } from '../utils/providerModels';

/**
 * Returns the model catalog as `{ provider: [ids] }`: the fallback lists at
 * first, each provider in `providers` replaced by the server's list as it
 * arrives. Loads again whenever `providers` names a different set.
 *
 * @param {string[]} providers - the providers to load
 * @returns {Object<string, string[]>}
 */
export function useProviderModels(providers) {
  const [catalog, setCatalog] = useState(FALLBACK_PROVIDER_MODELS);
  const key = providers.join(',');

  useEffect(() => {
    let cancelled = false;
    providers.forEach((provider) => {
      fetchProviderModels(provider).then((models) => {
        if (cancelled || models.length === 0) return;
        setCatalog((prev) => ({ ...prev, [provider]: models }));
      });
    });
    return () => { cancelled = true; };
  // `key` stands in for `providers`, which callers pass as a fresh array.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  return catalog;
}
