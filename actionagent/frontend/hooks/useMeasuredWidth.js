import { useEffect, useLayoutEffect, useState } from 'react';

// useLayoutEffect where there is a window to lay out, useEffect in a static
// render (where neither runs, so nothing is measured).
export const useIsoLayoutEffect = typeof window === 'undefined' ? useEffect : useLayoutEffect;

// An element's rendered width (clientWidth), kept current by a ResizeObserver
// (window resize when the browser lacks one). 0 until measured — and always
// 0 in a static render — so a caller reads 0 as "not measured yet".
export default function useMeasuredWidth(ref) {
  const [width, setWidth] = useState(0);
  useIsoLayoutEffect(() => {
    const el = ref.current;
    if (!el) return undefined;
    const measure = () => setWidth(el.clientWidth);
    measure();
    if (typeof ResizeObserver === 'undefined') {
      window.addEventListener('resize', measure);
      return () => window.removeEventListener('resize', measure);
    }
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, [ref]);
  return width;
}
