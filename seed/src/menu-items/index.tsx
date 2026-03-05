// project import
import other from './other';
import pages from './pages';
import samplePage from './sample-page';

// types
import { NavItemType } from 'types';

// ==============================|| MENU ITEMS ||============================== //

const menuItems: { items: NavItemType[] } = {
    items: [samplePage, pages, other]
};

export default menuItems;
