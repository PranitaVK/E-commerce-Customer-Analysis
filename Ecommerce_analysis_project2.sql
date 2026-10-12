--  Create a clean, relational database
drop database if exists ecommerce_analysis;
create database ecommerce_analysis;
use ecommerce_analysis;
create table customers(
customer_id int primary key auto_increment,
customer_name varchar(100) not null,
email varchar(100) not null unique,
city varchar(60),
signup_date date not null );
 create table products(
 product_id int primary key auto_increment,
 product_name varchar(120) not null,
 category varchar(60) not null,
 unit_price decimal(10,2) not null CHECK (unit_price >0));
 create table orders(order_id int primary key auto_increment,
 customer_id int not null,
 order_date date not null ,
 order_status enum ("Completed","Cancelled","Returned") not null default 'Completed',
 foreign key(customer_id) references customers(customer_id),
 index idx_orders_customer_date(customer_id,order_date)
 );
 Create table order_items (
  order_item_id BIGINT PRIMARY KEY AUTO_INCREMENT,
  order_id int not null,
  product_id int not null,
  quantity int not null check (quantity > 0),
  unit_price decimal(10,2) not null check (unit_price > 0),
  foreign key (order_id) references orders(order_id),
  foreign key (product_id) references products(product_id),
  index idx_items_order (order_id)
);

 INSERT INTO products (product_name, category, unit_price) VALUES
('Wireless Mouse','Electronics',699),('Bluetooth Headphones','Electronics',1999),
('T-Shirt','Fashion',499),('Jeans','Fashion',1299),('Coffee Mug','Home',349),
('Desk Lamp','Home',899),('Notebook','Stationery',149),('Water Bottle','Home',599),
('Phone Stand','Electronics',399),('Backpack','Fashion',1099);
 
-- 3) Generate demo data: 2,000 customers, 10,000 orders and 20,000 order lines.
DELIMITER $$
CREATE PROCEDURE generate_demo_data()
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE v_order_id INT;
  WHILE i <= 2000 DO
    INSERT INTO customers (customer_name,email,city,signup_date)
    VALUES (CONCAT('Customer ',i), CONCAT('customer',i,'@example.com'),
      ELT(1 + FLOOR(RAND()*6),'Mumbai','Delhi','Bengaluru','Chennai','Pune','Kolkata'),
      DATE_ADD('2023-01-01', INTERVAL FLOOR(RAND()*730) DAY));
    SET i = i + 1;
  END WHILE;
  SET i = 1;
  WHILE i <= 10000 DO
    SET @customer_id = 1 + FLOOR(RAND()*2000);

INSERT INTO orders (customer_id, order_date, order_status)
SELECT
    @customer_id,
    DATE_ADD(
        signup_date,
        INTERVAL FLOOR(
            RAND() * (DATEDIFF('2025-12-31', signup_date) + 1)
        ) DAY
    ),
    IF(RAND() < 0.88, 'Completed',
       IF(RAND() < 0.6, 'Cancelled', 'Returned'))
FROM customers
WHERE customer_id = @customer_id;
    SET v_order_id = LAST_INSERT_ID();
    INSERT INTO order_items (order_id,product_id,quantity,unit_price)
      SELECT v_order_id, p.product_id, 1 + FLOOR(RAND()*3), p.unit_price
      FROM products p WHERE p.product_id = 1 + FLOOR(RAND()*10);
    INSERT INTO order_items (order_id,product_id,quantity,unit_price)
      SELECT v_order_id, p.product_id, 1 + FLOOR(RAND()*2), p.unit_price
      FROM products p WHERE p.product_id = 1 + FLOOR(RAND()*10);
    SET i = i + 1;
  END WHILE;
END$$
DELIMITER ;
CALL generate_demo_data();
DROP PROCEDURE generate_demo_data;

-- DATA-INTEGRITY CHECKS (all should return 0)
SELECT 'Orders with no items' AS check_name, COUNT(*) AS problem_count
FROM orders o LEFT JOIN order_items oi ON oi.order_id=o.order_id WHERE oi.order_id IS NULL
UNION ALL
SELECT 'Invalid quantities', COUNT(*) FROM order_items WHERE quantity <= 0
UNION ALL
SELECT 'Invalid prices', COUNT(*) FROM order_items WHERE unit_price <= 0;

-- Create one reusable reporting view. Only completed orders are included.
CREATE OR REPLACE VIEW v_completed_order_sales AS
SELECT o.order_id, o.customer_id, o.order_date, c.customer_name, c.city,oi.product_id,p.product_name,
       p.category, oi.quantity, oi.unit_price, oi.quantity * oi.unit_price AS line_sales
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
JOIN order_items oi ON oi.order_id = o.order_id
JOIN products p ON p.product_id = oi.product_id
WHERE o.order_status = 'Completed';


--  CORE ANALYSIS: top 10 customers by revenue
select customer_id,customer_name,city,
  count(distinct order_id ) as completed_order,
  round(sum(line_sales),2) as total_spend
from v_completed_order_sales
group by customer_id,customer_name,city
order by total_spend desc limit 10;

-- Monthly sales trend (export this result to Excel)
select date_format(order_date,'%y-%m') as Sales_month,
  count(distinct order_id) as orders,
  round(sum(line_sales),2) as revenue from v_completed_order_sales 
group by date_format(order_date,'%y-%m')
order by Sales_month;

-- Seasonal trend: month across all years
select MONTHNAME(order_date) as month_name, month(order_date) as month_no,
  count(distinct order_id) as orders,
  round(sum(line_sales),2) as revenue from v_completed_order_sales
group by month(order_date),MONTHNAME(order_date)
order by month_no;

-- Sales by product category
select category ,count(distinct order_id) as orders,
round(sum(line_sales),2) as revenue from v_completed_order_sales 
group by category order by revenue desc;
	
--  High-churn customers: bought in the first period but not in the last 90 days.
-- The date is calculated from the latest completed order, so it works with any data period.
WITH latest AS (SELECT MAX(order_date) AS max_date FROM v_completed_order_sales),
customer_activity AS (
  SELECT customer_id, customer_name, MAX(order_date) AS last_purchase,
         COUNT(DISTINCT order_id) AS lifetime_orders, SUM(line_sales) AS lifetime_spend
  FROM v_completed_order_sales GROUP BY customer_id, customer_name
)
SELECT ca.customer_id, ca.customer_name, ca.last_purchase, ca.lifetime_orders,
       ROUND(ca.lifetime_spend,2) AS lifetime_spend
FROM customer_activity ca CROSS JOIN latest l
WHERE ca.last_purchase < DATE_SUB(l.max_date, INTERVAL 90 DAY)
ORDER BY ca.lifetime_spend DESC;

-- Subquery example: customers who spend more than average customer spend
select customer_id,customer_name ,round(sum(line_sales),2) as total_spend
from v_completed_order_sales
group by customer_id,customer_name 
having sum(line_sales)> (
select avg(customer_spend) from (select sum(line_sales) as customer_spend
from v_completed_order_sales group by customer_id) as spends)
order by total_spend desc;

-- average customer spending 
select round(avg(customer_spend),2) as avg_customer_spend
from (select sum(line_sales) as customer_spend
from v_completed_order_sales group by customer_id) t;

-- customers that have made most orders
select customer_id,customer_name, 
count(distinct order_id) as total_orders 
from v_completed_order_sales
group by customer_id,customer_name 
order by total_orders desc limit 10;

-- which cities generate most revenue 
select city,
count(distinct order_id) as orders, 
round(sum(line_sales),2) as revenue 
from v_completed_order_sales
group by city
order by revenue desc;

-- Top-selling products
select product_id , category,
sum(quantity) as units_sold,
round(sum(line_sales),2) as revenue 
from v_completed_order_sales 
group by product_id ,category
order by units_sold desc limit 10;

-- order status analysis
SELECT
    order_status,
    COUNT(*) AS total_orders,
    ROUND(
        COUNT(*) * 100.0 / (SELECT COUNT(*) FROM orders),
        2
    ) AS percentage
FROM orders
GROUP BY order_status;

-- cancellation and return analysis
select year(order_date),order_status,
count(*) as Total_orders from orders
group by year(order_date),order_status
order by year(order_date),order_status;

-- average order value
select round(sum(line_sales)/ count(distinct order_id),2) as Avg_order_value 
from v_completed_order_sales;

-- repeat v/s one time customer using case
select
  case
    when order_count = 1 then 'One Time Customer'
    else 'Repeat Customer'
  end as Customer_type,
  count(*) as Customers 
from (
  select customer_id,
  count(distinct order_id) as order_count
  from v_completed_order_sales
  group by customer_id
  )t
  group by Customer_type;
 
 -- Customer Segmentation
select customer_id,customer_name,total_spend ,
 case 
  when total_spend >= 5000 then 'High Value'
  when total_spend >= 2000 then 'Medium value'
  else 'Low Value'
  end as Customer_segment
from (  
select customer_id,customer_name,
round(sum(line_sales),2) as total_spend 
from v_completed_order_sales  
group by customer_id,customer_name
)t
order by total_spend;

-- RFM analysis
-- Recency → How recently did the customer purchase
-- Frequency → How often did they purchase
-- Monetary → How much did they spend
select
 customer_id,customer_name,
 datediff( 
   (select max(order_date) from v_completed_order_sales),
max(order_date)
) as recent_days,
count(distinct order_id) as Frequency,
round(sum(line_sales),2) as monetary
from v_completed_order_sales 
group by customer_id,customer_name ;

-- another customer level view 
CREATE OR REPLACE VIEW v_customer_summary AS
SELECT
    customer_id,
    customer_name,
    city,
    COUNT(DISTINCT order_id) AS total_orders,
    MAX(order_date) AS last_purchase_date,
    ROUND(SUM(line_sales), 2) AS lifetime_spend,
    ROUND(SUM(line_sales) / COUNT(DISTINCT order_id), 2) AS avg_order_value
FROM v_completed_order_sales
GROUP BY customer_id, customer_name, city;
SELECT *
FROM v_customer_summary
ORDER BY lifetime_spend DESC;





  








describe products;
desc v_completed_order_sales








 
