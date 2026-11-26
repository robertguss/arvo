import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { LoginPageProps } from "../arvo.gen";
import Login from "../pages/Login";
import { loadMoFixture } from "./fixtures";

const loginErrorFixture = loadMoFixture<LoginPageProps>("Login", "login_error");
const loginGuestFixture = loadMoFixture<LoginPageProps>("Login", "login_guest");

const { postMock, setDataMock, useFormState } = vi.hoisted(() => ({
  postMock: vi.fn(),
  setDataMock: vi.fn(),
  useFormState: { processing: false },
}));

vi.mock("@inertiajs/react", () => ({
  useForm: (initial: { email: string; password: string }) => ({
    data: initial,
    setData: setDataMock,
    post: postMock,
    processing: useFormState.processing,
  }),
}));

describe("Login component with real Mo Inertia fixtures", () => {
  beforeEach(() => {
    postMock.mockReset();
    setDataMock.mockReset();
    useFormState.processing = false;
  });

  it("renders guest login fixture with accessible labels and submits /login", async () => {
    const user = userEvent.setup();
    const props = loginGuestFixture.props as unknown as LoginPageProps;
    render(<Login {...props} />);

    expect(screen.getByRole("heading", { name: "Sign in to Arvo" })).toBeInTheDocument();
    expect(screen.getByText(props.allowlist_hint)).toBeInTheDocument();

    const emailInput = screen.getByLabelText("Email");
    const passwordInput = screen.getByLabelText("Password");
    expect(emailInput).toHaveAttribute("aria-invalid", "false");
    expect(emailInput).not.toHaveAttribute("aria-describedby");
    expect(passwordInput).toHaveAttribute("aria-invalid", "false");
    expect(passwordInput).not.toHaveAttribute("aria-describedby");

    await user.type(emailInput, "a");
    expect(setDataMock).toHaveBeenCalledWith("email", "a");
    await user.type(passwordInput, "p");
    expect(setDataMock).toHaveBeenCalledWith("password", "p");

    const submitBtn = screen.getByRole("button", { name: "Sign in" });
    expect(submitBtn).toBeEnabled();
    await user.click(submitBtn);
    expect(postMock).toHaveBeenCalledWith("/login");
  });

  it("renders real validation errors, alert banners, and disabled state", () => {
    useFormState.processing = true;
    const baseProps = loginErrorFixture.props as unknown as LoginPageProps;
    const props: LoginPageProps = {
      ...baseProps,
      flash: { notice: null, alert: "Session expired" },
      errors: { ...baseProps.errors, password: "invalid password" },
    };
    render(<Login {...props} />);

    expect(screen.getByRole("button", { name: "Sign in" })).toBeDisabled();
    const alerts = screen.getAllByRole("alert");
    expect(alerts.some((el) => el.textContent?.includes("Session expired"))).toBe(true);
    expect(alerts.some((el) => el.textContent?.includes("allowlist"))).toBe(true);
    expect(alerts.some((el) => el.textContent?.includes("invalid password"))).toBe(true);

    expect(screen.getByLabelText("Email")).toHaveAttribute("aria-invalid", "true");
    expect(screen.getByLabelText("Email")).toHaveAttribute("aria-describedby", "email-error");
    expect(screen.getByLabelText("Password")).toHaveAttribute("aria-invalid", "true");
    expect(screen.getByLabelText("Password")).toHaveAttribute("aria-describedby", "password-error");
  });
});
