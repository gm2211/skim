import { useId, type ReactNode } from 'react';
import { ChatGPTMark, type ChatGPTMarkVariant } from './ChatGPTMark.js';

export type SignInWithChatGPTStatus = 'idle' | 'pending' | 'success' | 'error' | 'unavailable';

export interface SignInWithChatGPTStrings {
  heading: string;
  description: string;
  button: string;
  pending: string;
  success: string;
  error: string;
  unavailable: string;
}

export const defaultSignInWithChatGPTStrings: SignInWithChatGPTStrings = {
  heading: 'Sign in with ChatGPT',
  description: 'Use your ChatGPT account to sign in to this app.',
  button: 'Continue with ChatGPT',
  pending: 'Opening ChatGPT sign-in…',
  success: 'You are signed in with ChatGPT.',
  error: 'ChatGPT sign-in could not be completed. Try again.',
  unavailable: 'ChatGPT sign-in is not available right now.',
};

export interface SignInWithChatGPTProps {
  /** Application route that creates the server-side OIDC transaction and redirects to OpenAI. */
  href: string;
  status?: SignInWithChatGPTStatus;
  /** Optional host copy for pending, success, error, or unavailable state. */
  message?: string;
  /** Called synchronously on a normal enabled click before following the start route. */
  onStart?: () => void;
  /** Product-specific disclosure; the component never describes plan usage as identity sign-in. */
  disclosure?: ReactNode;
  strings?: Partial<SignInWithChatGPTStrings>;
  headingId?: string;
  variant?: ChatGPTMarkVariant;
  className?: string;
}


/**
 * Shared website identity presentation for the approved Sign in with ChatGPT website flow.
 * This is OpenID identity only; it does not connect ChatGPT plan usage or provider credentials.
 */
export function SignInWithChatGPT({
  href,
  status = 'idle',
  message,
  onStart,
  disclosure,
  strings: overrides,
  headingId,
  variant = 'black',
  className = '',
}: SignInWithChatGPTProps) {
  const strings = { ...defaultSignInWithChatGPTStrings, ...overrides };
  const generatedId = useId();
  const resolvedHeadingId = headingId ?? `byos-chatgpt-identity-${generatedId}`;
  const disabled = status === 'pending' || status === 'success' || status === 'unavailable';
  const statusMessage = message ?? (status === 'pending' ? strings.pending
    : status === 'success' ? strings.success
      : status === 'error' ? strings.error
        : status === 'unavailable' ? strings.unavailable : undefined);
  const classes = ['byos-chatgpt-identity', className].filter(Boolean).join(' ');
  return <section className={classes} aria-labelledby={resolvedHeadingId} aria-busy={status === 'pending' || undefined}>
    <header className="byos-chatgpt-identity-heading">
      <h2 id={resolvedHeadingId}>{strings.heading}</h2>
      <p>{strings.description}</p>
    </header>
    {disabled
      ? <button className={`byos-chatgpt-identity-button byos-chatgpt-identity-${variant}`} type="button" disabled>
        <ChatGPTMark variant={variant}/>
        <span>{strings.button}</span>
      </button>
      : <a className={`byos-chatgpt-identity-button byos-chatgpt-identity-${variant}`} href={href} onClick={event => {
        if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        onStart?.();
      }}>
        <ChatGPTMark variant={variant}/>
        <span>{strings.button}</span>
      </a>}
    {statusMessage && <p className={`byos-chatgpt-identity-status byos-chatgpt-identity-status-${status}`} role={status === 'error' ? 'alert' : 'status'} aria-live={status === 'error' ? 'assertive' : 'polite'}>{statusMessage}</p>}
    {disclosure && <div className="byos-chatgpt-identity-disclosure">{disclosure}</div>}
  </section>;
}
