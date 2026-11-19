/* @refresh reload */
import { render } from "solid-js/web";
import { Router, Route } from "@solidjs/router";
import { lazy } from "solid-js";
import "./styles.css";
import Layout from "./App.jsx";
import { Home, Product, StorePage } from "./pages/shop.jsx";
import { Login, Register, Account } from "./pages/auth.jsx";
import { CartPage, Checkout, Orders, OrderDetail } from "./pages/orders.jsx";
import { Chats, Thread } from "./pages/chat.jsx";

// Seller and admin screens are rarely opened by shoppers: load them on demand.
const seller = (name) => lazy(() => import("./pages/seller.jsx").then((m) => ({ default: m[name] })));
const admin = (name) => lazy(() => import("./pages/admin.jsx").then((m) => ({ default: m[name] })));

render(
  () => (
    <Router root={Layout}>
      <Route path="/" component={Home} />
      <Route path="/p/:id" component={Product} />
      <Route path="/store/:id" component={StorePage} />
      <Route path="/login" component={Login} />
      <Route path="/register" component={Register} />
      <Route path="/account" component={Account} />
      <Route path="/cart" component={CartPage} />
      <Route path="/checkout" component={Checkout} />
      <Route path="/orders" component={Orders} />
      <Route path="/orders/:id" component={OrderDetail} />
      <Route path="/chats" component={Chats} />
      <Route path="/chats/:id" component={Thread} />
      <Route path="/seller" component={seller("SellerHome")} />
      <Route path="/seller/store" component={seller("StoreEdit")} />
      <Route path="/seller/products" component={seller("SellerProducts")} />
      <Route path="/seller/products/:id" component={seller("ProductEdit")} />
      <Route path="/seller/orders" component={seller("SellerOrders")} />
      <Route path="/admin" component={admin("Admin")} />
      <Route path="*" component={() => <div class="gate"><h2>Page not found</h2><a class="btn primary" href="/">Go home</a></div>} />
    </Router>
  ),
  document.getElementById("root"),
);
