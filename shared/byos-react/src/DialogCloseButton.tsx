import type { ButtonHTMLAttributes } from 'react';
import { ByosIcon } from './icons.js';

export type DialogCloseButtonProps = Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'type' | 'children'>;

/** A close affordance for a host-owned dialog. Placement and dismissal stay with the caller. */
export function DialogCloseButton({ 'aria-label': ariaLabel = 'Close', className, ...props }: DialogCloseButtonProps) {
  return <button {...props} type="button" aria-label={ariaLabel} className={`byos-dialog-close${className ? ` ${className}` : ''}`}>
    <ByosIcon name="close" size={20}/>
  </button>;
}
