import { useEffect, useRef, useCallback } from 'react';
import { createConsumer } from '@rails/actioncable';

// Singleton consumer to reuse across components
let consumer = null;

function getConsumer() {
  if (consumer === null) {
    try {
      consumer = createConsumer();
    } catch (error) {
      // No Action Cable mount in this app. Live run updates go quiet; the
      // views that use them fall back to polling.
      consumer = false;
    }
  }
  return consumer || null;
}

/**
 * Hook to subscribe to ActionCable channels
 * @param {string} channelName - Name of the channel to subscribe to
 * @param {object} params - Parameters to pass to the channel
 * @param {function} onReceived - Callback when message is received
 * @param {boolean} enabled - Whether subscription is enabled
 */
export function useActionCable(channelName, params, onReceived, enabled = true) {
  const subscriptionRef = useRef(null);
  const onReceivedRef = useRef(onReceived);

  // Keep callback ref up to date
  useEffect(() => {
    onReceivedRef.current = onReceived;
  }, [onReceived]);

  useEffect(() => {
    if (!enabled || !channelName) {
      return;
    }

    const cable = getConsumer();

    // Create subscription
    subscriptionRef.current = cable.subscriptions.create(
      { channel: channelName, ...params },
      {
        connected() {
          console.log(`[ActionCable] Connected to ${channelName}`, params);
        },
        disconnected() {
          console.log(`[ActionCable] Disconnected from ${channelName}`);
        },
        received(data) {
          console.log(`[ActionCable] Received on ${channelName}:`, data);
          if (onReceivedRef.current) {
            onReceivedRef.current(data);
          }
        },
        rejected() {
          console.warn(`[ActionCable] Subscription rejected for ${channelName}`);
        }
      }
    );

    // Cleanup subscription on unmount
    return () => {
      if (subscriptionRef.current) {
        console.log(`[ActionCable] Unsubscribing from ${channelName}`);
        subscriptionRef.current.unsubscribe();
        subscriptionRef.current = null;
      }
    };
  }, [channelName, JSON.stringify(params), enabled]);

  // Method to send data to the channel
  const send = useCallback((action, data) => {
    if (subscriptionRef.current) {
      subscriptionRef.current.perform(action, data);
    }
  }, []);

  return { send };
}

export default useActionCable;
