import { InputHTMLAttributes, useEffect, useRef, useState } from "react";

type BaseProps = Omit<
  InputHTMLAttributes<HTMLInputElement>,
  "value" | "onChange" | "type"
>;

type StrictProps = BaseProps & {
  value: number;
  fallback: number;
  onChange: (n: number) => void;
};

type NullableProps = BaseProps & {
  value: number | null | undefined;
  fallback?: undefined;
  onChange: (n: number | null) => void;
};

export type NumberInputProps = StrictProps | NullableProps;

export function NumberInput(props: NumberInputProps) {
  const { value, fallback, onChange, onBlur, ...rest } = props;
  const initial = value == null ? "" : String(value);
  const [raw, setRaw] = useState(initial);
  const lastValRef = useRef<number | null>(value ?? null);

  useEffect(() => {
    const incoming = value ?? null;
    if (incoming !== lastValRef.current) {
      setRaw(value == null ? "" : String(value));
      lastValRef.current = incoming;
    }
  }, [value]);

  return (
    <input
      {...rest}
      type="number"
      value={raw}
      onChange={(e) => {
        const v = e.target.value;
        setRaw(v);
        if (v === "") return;
        const n = Number(v);
        if (Number.isFinite(n)) {
          lastValRef.current = n;
          (onChange as (n: number | null) => void)(n);
        }
      }}
      onBlur={(e) => {
        const v = raw;
        const n = Number(v);
        const empty = v === "" || !Number.isFinite(n);
        if (empty) {
          if (fallback != null) {
            setRaw(String(fallback));
            lastValRef.current = fallback;
            (onChange as (n: number) => void)(fallback);
          } else {
            lastValRef.current = null;
            (onChange as (n: number | null) => void)(null);
          }
        }
        onBlur?.(e);
      }}
    />
  );
}
